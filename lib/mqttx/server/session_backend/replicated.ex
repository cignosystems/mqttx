defmodule MqttX.Server.SessionBackend.Replicated do
  @moduledoc """
  A `MqttX.Server.SessionBackend` that keeps every saved session on every
  node running the listener, in memory: when a node goes down, a client of
  its resumes its session on any other node.

      MqttX.Server.start_link(MyBroker, [],
        name: MyApp.Broker,
        port: 1883,
        session_backend: MqttX.Server.SessionBackend.Replicated
      )

  Each save goes to every other node of the listener's group (the listeners
  with the same `:name` on connected nodes, see `MqttX.Server.Cluster`), and
  a node that joins is sent what the others hold. A record carries the node
  that saved it and a version; a node keeps the newest version of each
  session, so a save that arrives late cannot replace a newer one. Versions
  combine the wall clock with the version they replace, which orders the
  saves of a session moving between nodes as long as the nodes' clocks
  agree to within the time the move takes.

  Costs: every node holds every persistent session, and each change to one
  is sent to every node (once per `:session_flush_interval`, like any
  backend). A node that dies loses at most that much of its sessions'
  changes; a session saved while connected starts its expiry clock when its
  node leaves.

  The records live as long as one node runs the listener: a restart of the
  whole cluster loses them. For that, implement the behaviour over a
  database.
  """

  @behaviour MqttX.Server.SessionBackend

  use GenServer

  @scope MqttX.Server.Cluster
  @sweep_interval 60_000
  @sync_chunk 500
  # How long (s) a deleted session is remembered, so a save of it from
  # before the delete, arriving late, does not bring it back
  @deleted_ttl 3_600

  # ---------- The backend ----------

  @impl MqttX.Server.SessionBackend
  def init(listener, _opts) do
    spec = %{
      id: {__MODULE__, listener},
      start: {GenServer, :start_link, [__MODULE__, listener]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(MqttX.Server.Cluster.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, %{listener: listener, table: table(listener)}}
  end

  @impl MqttX.Server.SessionBackend
  def save(%{listener: listener, table: table}, client_id, record) do
    version = next_version(table, client_id)
    :ets.insert(table, {client_id, record, version})
    broadcast(listener, {:save, client_id, record, version})
    :ok
  end

  @impl MqttX.Server.SessionBackend
  def load(%{table: table}, client_id) do
    case :ets.lookup(table, client_id) do
      [{_, record, _version}] when record != nil -> {:ok, record}
      _ -> :none
    end
  end

  @impl MqttX.Server.SessionBackend
  def delete(%{listener: listener, table: table}, client_id) do
    version = next_version(table, client_id)
    apply_delete(table, client_id, node(), version)
    broadcast(listener, {:delete, client_id, node(), version})
    :ok
  end

  @impl MqttX.Server.SessionBackend
  def list(%{table: table}) do
    for {client_id, record, _version} <- :ets.tab2list(table),
        record != nil,
        do: {client_id, record}
  end

  # ---------- The process that holds the table and talks to the others ----------

  @impl GenServer
  def init(listener) do
    :ets.new(table(listener), [:named_table, :public, :set, read_concurrency: true])
    :ok = :pg.join(@scope, group(listener), self())
    {ref, others} = :pg.monitor(@scope, group(listener))
    state = %{listener: listener, table: table(listener), monitor: ref}
    Enum.each(others, &sync_to(&1, state))
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:save, client_id, record, version}, state) do
    apply_save(state.table, client_id, record, version)
    {:noreply, state}
  end

  def handle_info({:delete, client_id, node, version}, state) do
    apply_delete(state.table, client_id, node, version)
    {:noreply, state}
  end

  def handle_info({:sync, rows}, state) do
    for {client_id, record, version} <- rows,
        do: apply_save(state.table, client_id, record, version)

    {:noreply, state}
  end

  def handle_info({ref, :join, _group, pids}, %{monitor: ref} = state) do
    Enum.each(pids, &sync_to(&1, state))
    {:noreply, state}
  end

  # Sessions saved while connected on a node that left start their expiry
  # clock now: nobody will save them again
  def handle_info({ref, :leave, _group, pids}, %{monitor: ref} = state) do
    still_there = MapSet.new(:pg.get_members(@scope, group(state.listener)), &node/1)
    gone = for pid <- pids, not MapSet.member?(still_there, node(pid)), do: node(pid)
    now = System.system_time(:second)

    for node <- gone,
        {client_id, %{meta: meta} = record, version} <-
          :ets.select(state.table, [
            {{:_, %{node: node, meta: %{expires_at: :infinity}}, :_}, [], [:"$_"]}
          ]) do
      expires_at =
        case Map.get(meta, :lifetime) do
          lifetime when is_integer(lifetime) and lifetime < 0xFFFFFFFF -> now + lifetime
          _ -> :infinity
        end

      record = %{record | meta: %{meta | expires_at: expires_at}}
      :ets.insert(state.table, {client_id, record, version})
    end

    {:noreply, state}
  end

  # Each node forgets expired sessions, and old deletes, on its own
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    cutoff = System.system_time(:microsecond) - @deleted_ttl * 1_000_000

    :ets.select_delete(state.table, [
      {{:_, %{meta: %{expires_at: :"$1"}}, :_}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]},
      {{:_, nil, {:"$1", :_}}, [{:<, :"$1", cutoff}], [true]}
    ])

    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------- Helpers ----------

  defp group(listener), do: {__MODULE__, listener}

  defp table(listener), do: :"#{__MODULE__}.#{:erlang.phash2(listener)}"

  defp broadcast(listener, message) do
    for pid <- :pg.get_members(@scope, group(listener)),
        node(pid) != node(),
        do: send(pid, message)
  end

  # A chunk at a time, so a large table is not copied into one message
  defp sync_to(pid, state) when node(pid) != node(),
    do: send_chunks(pid, :ets.select(state.table, [{:_, [], [:"$_"]}], @sync_chunk))

  defp sync_to(_pid, _state), do: :ok

  defp send_chunks(_pid, :"$end_of_table"), do: :ok

  defp send_chunks(pid, {rows, continuation}) do
    send(pid, {:sync, rows})
    send_chunks(pid, :ets.select(continuation))
  end

  # Later than the clock and than the version this node has for the session
  defp next_version(table, client_id) do
    now = System.system_time(:microsecond)

    case :ets.lookup(table, client_id) do
      [{_, _, {time, _node}}] when time >= now -> {time + 1, node()}
      _ -> {now, node()}
    end
  end

  defp apply_save(table, client_id, record, version) do
    case :ets.lookup(table, client_id) do
      [{_, _, stored}] when stored >= version -> :ok
      _ -> :ets.insert(table, {client_id, record, version})
    end
  end

  # Only the node that saved the session deletes it, and not a newer save;
  # the delete is remembered (a `nil` record) for an hour
  defp apply_delete(table, client_id, node, version) do
    case :ets.lookup(table, client_id) do
      [{_, %{node: ^node}, stored}] when stored <= version ->
        :ets.insert(table, {client_id, nil, version})

      _ ->
        :ok
    end
  end
end
