defmodule MqttX.Server.Cluster do
  @moduledoc """
  One broker across several nodes.

  When the node is part of an Erlang cluster, the listeners started with the
  same `:name` on each node form a group (via `:pg`). Nothing is configured:
  a listener joins its group when it starts, and on a node that is not
  distributed the group has one member and none of this costs anything.
  Within a group:

    * `MqttX.Server.deliver/3` fans a message out on every node.
    * A client may connect to any node. Its CONNECT reaches every other node
      of the group, which disconnects a connection it still holds for that
      client id (§3.1.4 takeover), cancels its pending Will Delay and
      Session Expiry, and hands its stored session over (Clean Start 0) or
      discards it (Clean Start 1).
    * Retained messages are replicated to every node; a node that joins
      receives the others' retained messages. Concurrent writes to one topic
      resolve to the latest (by wall-clock second).
    * A shared subscription (§4.8) delivers each message once across the
      cluster: shared group membership is replicated, and the delivering node
      picks one member wherever it is connected.

  A session lives on one node at a time. A node that goes down takes its
  sessions with it, unless the listener has a `MqttX.Server.SessionBackend`
  that the other nodes reach too. `docs/design/clustering.md` has the design
  notes.
  """

  use GenServer

  require Logger

  alias MqttX.Server.Delivery
  alias MqttX.Server.RetainedStore
  alias MqttX.Server.SessionExpiry
  alias MqttX.Server.SessionStore
  alias MqttX.Server.WillDelay

  @scope __MODULE__

  # How long a CONNECT waits for the other nodes to release a session. A
  # node that answers later has its session discarded, not moved.
  @claim_timeout 5_000
  # Within that, how long a node waits for its own connection to let go
  @takeover_timeout 4_000

  @doc false
  def scope, do: @scope

  @doc false
  # Called by MqttX.Server.register_listener/2: one member per listener per
  # node, its context replaced when the listener restarts under the same name.
  # A durable backend's sessions are loaded first, before any client can
  # connect.
  def join(listener, ctx) do
    restored = SessionStore.restore(ctx.sessions)

    if restored > 0 do
      Logger.info("[MqttX.Server] Restored #{restored} session(s) for #{inspect(listener)}")
    end

    spec = %{
      id: {__MODULE__, listener},
      start: {__MODULE__, :start_link, [listener, ctx]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(MqttX.Server.Cluster.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> GenServer.call(pid, {:context, ctx})
    end
  end

  @doc false
  def start_link(listener, ctx) do
    GenServer.start_link(__MODULE__, {listener, ctx}, name: via(listener))
  end

  defp via(listener), do: {:via, Registry, {MqttX.Server.Cluster.Registry, listener}}

  @doc "The member processes of a listener's group, one per node that runs it."
  @spec members(term()) :: [pid()]
  def members(listener), do: :pg.get_members(@scope, listener)

  @doc false
  def remote_members(listener) do
    for pid <- members(listener), node(pid) != node(), do: pid
  end

  # ---------- Called on the node where something happened ----------

  @doc false
  # Hand a (codec-encoded) message to every other node's member for its own
  # local fan-out
  def deliver(listener, topic, payload, opts) do
    broadcast(listener, {:deliver, topic, payload, opts})
  end

  @doc false
  # A shared group's member on `node` was picked for this message
  def deliver_to(listener, node, client_id, topic, payload, opts) do
    case Enum.find(remote_members(listener), &(node(&1) == node)) do
      nil -> :ok
      pid -> send(pid, {:deliver_to, client_id, topic, payload, opts})
    end

    :ok
  end

  @doc false
  # A shared subscription came or went on this node
  def shared_changed(listener, op), do: broadcast(listener, {:shared, node(), op})

  @doc false
  # Write a retained message (or clear one) and replicate the write
  def store_retained(listener, table, topic, payload, qos, properties, max) do
    case RetainedStore.write(table, topic, payload, qos, properties, max) do
      :dropped -> :ok
      change -> if listener, do: broadcast(listener, {:retained, change}), else: :ok
    end
  end

  @doc false
  # What another node knows about a session, without changing anything: its
  # subscriptions if one holds it. For handle_connect/4, before the CONNECT is
  # authorized.
  @spec lookup(term(), binary()) :: {:ok, [map()]} | :none
  def lookup(listener, client_id), do: ask(listener, client_id, :peek)

  @doc false
  # An authorized CONNECT for `client_id` on this node: every other node lets
  # go of the client (takeover, timers) and of its session — handing it over
  # for Clean Start 0 (`:take`), discarding it for Clean Start 1 (`:clean`).
  @spec claim(term(), binary(), :take | :clean) :: {:ok, SessionStore.session_record()} | :none
  def claim(listener, client_id, mode) when mode in [:take, :clean] do
    ask(listener, client_id, mode)
  end

  defp ask(listener, client_id, mode) do
    case remote_members(listener) do
      [] ->
        :none

      members ->
        # Replies go to an alias, so one arriving after the deadline is
        # dropped instead of landing in the connection's mailbox
        reply_to = :erlang.alias()
        Enum.each(members, &send(&1, {:claim, reply_to, client_id, mode}))
        deadline = System.monotonic_time(:millisecond) + @claim_timeout
        result = collect(reply_to, length(members), deadline, :none)
        :erlang.unalias(reply_to)
        result
    end
  end

  defp collect(_reply_to, 0, _deadline, result), do: result

  defp collect(reply_to, pending, deadline, result) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply_to, {:ok, _} = found} -> collect(reply_to, pending - 1, deadline, found)
      {^reply_to, :none} -> collect(reply_to, pending - 1, deadline, result)
    after
      timeout -> result
    end
  end

  defp broadcast(listener, message) do
    Enum.each(remote_members(listener), &send(&1, message))
  end

  # ---------- The member ----------

  @impl true
  def init({listener, ctx}) do
    :ok = :pg.join(@scope, listener, self())
    {ref, members} = :pg.monitor(@scope, listener)
    state = %{listener: listener, ctx: ctx, monitor: ref}

    # Whoever is already there learns what this node holds (and tells this
    # node what it holds when it sees the join)
    Enum.each(members, &sync_to(&1, state))
    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_call({:context, ctx}, _from, state), do: {:reply, :ok, %{state | ctx: ctx}}

  @impl true
  def handle_info({:deliver, topic, payload, opts}, state) do
    guarded(fn -> Delivery.deliver_local(state.ctx, topic, payload, opts) end)
    {:noreply, state}
  end

  def handle_info({:deliver_to, client_id, topic, payload, opts}, state) do
    guarded(fn -> Delivery.deliver_to(state.ctx, client_id, topic, payload, opts) end)
    {:noreply, state}
  end

  def handle_info({:claim, reply_to, client_id, mode}, state) do
    # A takeover waits for the connection to let go; deliveries meanwhile
    # must not queue up behind it
    ctx = state.ctx
    spawn(fn -> send(reply_to, {reply_to, serve_claim(ctx, client_id, mode)}) end)
    {:noreply, state}
  end

  def handle_info({:shared, node, {:add, segments, group, client_id, opts}}, state) do
    sessions = state.ctx.sessions

    guarded(fn ->
      SessionStore.put_remote_shared(sessions, node, segments, group, client_id, opts)
    end)

    {:noreply, state}
  end

  def handle_info({:shared, node, {:remove, segments, group, client_id, _opts}}, state) do
    guarded(fn ->
      SessionStore.delete_remote_shared(state.ctx.sessions, node, segments, group, client_id)
    end)

    {:noreply, state}
  end

  def handle_info({:retained, change}, state) do
    guarded(fn ->
      RetainedStore.apply_replica(state.ctx.retained_table, change, max_retained(state))
    end)

    {:noreply, state}
  end

  def handle_info({:sync, node, retained, shared}, state) do
    %{retained_table: table, sessions: sessions} = state.ctx
    max = max_retained(state)

    guarded(fn ->
      Enum.each(retained, &RetainedStore.apply_replica(table, {:stored, &1}, max))

      for {segments, group, client_id, opts} <- shared,
          do: SessionStore.put_remote_shared(sessions, node, segments, group, client_id, opts)
    end)

    {:noreply, state}
  end

  def handle_info({ref, :join, _group, pids}, %{monitor: ref} = state) do
    Enum.each(pids, &sync_to(&1, state))
    {:noreply, state}
  end

  def handle_info({ref, :leave, _group, pids}, %{monitor: ref} = state) do
    # Its shared subscriptions went with it; its sessions too, unless a
    # shared backend has them
    for pid <- pids, node(pid) != node() do
      guarded(fn -> SessionStore.drop_remote_node(state.ctx.sessions, node(pid)) end)
    end

    {:noreply, state}
  end

  def handle_info(:flush, state) do
    guarded(fn ->
      SessionStore.sweep(state.ctx.sessions)
      SessionStore.flush(state.ctx.sessions)
    end)

    {:noreply, schedule_flush(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    guarded(fn -> SessionStore.flush(state.ctx.sessions) end)
  end

  defp sync_to(pid, state) when node(pid) != node() do
    guarded(fn ->
      send(
        pid,
        {:sync, node(), RetainedStore.rows(state.ctx.retained_table),
         SessionStore.local_shared(state.ctx.sessions)}
      )
    end)
  end

  defp sync_to(_pid, _state), do: :ok

  # The listener's tables may be gone if it stopped without this node's member
  # going with it; a stale member must not take the group down
  defp guarded(fun) do
    fun.()
  rescue
    e -> Logger.debug("[MqttX.Server.Cluster] skipped: #{Exception.message(e)}")
  end

  defp max_retained(state), do: Map.get(state.ctx, :max_retained_messages)

  defp schedule_flush(%{ctx: %{sessions: %{backend: nil}}} = state), do: state

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, Map.get(state.ctx, :session_flush_interval, 1_000))
    state
  end

  # On the node that holds the client or its session, for a CONNECT elsewhere
  defp serve_claim(ctx, client_id, :peek) do
    case SessionStore.get(ctx.sessions, client_id) do
      nil -> :none
      _meta -> {:ok, SessionStore.subscriptions(ctx.sessions, client_id)}
    end
  rescue
    _ -> :none
  end

  defp serve_claim(ctx, client_id, mode) do
    take_over_connections(ctx, client_id)
    scope = {ctx.retained_table, client_id}
    WillDelay.cancel(scope)
    SessionExpiry.cancel(scope)

    case mode do
      :clean ->
        SessionStore.delete(ctx.sessions, client_id)
        :none

      :take ->
        case SessionStore.export(ctx.sessions, client_id) do
          nil ->
            :none

          record ->
            SessionStore.delete(ctx.sessions, client_id)
            {:ok, record}
        end
    end
  rescue
    e ->
      Logger.debug("[MqttX.Server.Cluster] claim failed: #{Exception.message(e)}")
      :none
  end

  # The same handshake a local takeover uses (§3.1.4): the connection
  # disconnects with 0x8E and says when it has stopped writing to the session
  defp take_over_connections(ctx, client_id) do
    key = {ctx.retained_table, client_id}

    for {pid, _} <- Registry.lookup(MqttX.Server.ConnectionRegistry, key) do
      ref = Process.monitor(pid)
      send(pid, {:session_takeover, self()})

      receive do
        {:session_released, ^pid} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @takeover_timeout -> Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end
end
