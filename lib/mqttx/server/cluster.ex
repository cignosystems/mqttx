defmodule MqttX.Server.Cluster do
  @moduledoc """
  One broker across several nodes.

  When the node is part of an Erlang cluster, the listeners started with the
  same `:name` on each node form a group (via `:pg`). Nothing is configured:
  a listener joins its group when it starts, and on a node that is not
  distributed the group has one member and none of this costs anything.
  Within a group:

    * `MqttX.Server.deliver/3` fans a message out on every node with a
      matching subscription: each node tells the others which filters its
      sessions subscribe to.
    * A client may connect to any node. Its CONNECT reaches every other node
      of the group, which disconnects a connection it still holds for that
      client id (§3.1.4 takeover), cancels its pending Will Delay and
      Session Expiry, and hands its stored session over (Clean Start 0) or
      discards it (Clean Start 1).
    * Retained messages are replicated to every node; a node that joins
      receives the others' retained messages. Concurrent writes to one topic
      resolve to the latest, and a clear is remembered for an hour, so a
      node that missed it cannot bring the message back.
    * A shared subscription (§4.8) delivers each message once across the
      cluster: shared group membership is replicated, and the delivering node
      picks one member wherever it is connected. The node holding that member
      answers whether it took the message; if not — its client is offline,
      its session is gone, or the node leaves before answering — the next
      member is picked, a connected one first.

  A session lives on one node at a time. While it moves, the node it left
  forwards what it matches for it and the node it moved to drops the copies
  it already has, and holds back what it matches itself until everything
  sent to the old node before the move has been forwarded — so a message
  published meanwhile is delivered once, in its publisher's order. A node
  that goes down takes its sessions with it, unless the listener has a
  `MqttX.Server.SessionBackend` that the other nodes reach too
  (`MqttX.Server.SessionBackend.Replicated`). `docs/design/clustering.md`
  has the design notes.
  """

  use GenServer

  require Logger

  alias MqttX.Server.Cluster.Relay
  alias MqttX.Server.Delivery
  alias MqttX.Server.RetainedStore
  alias MqttX.Server.SessionExpiry
  alias MqttX.Server.SessionStore
  alias MqttX.Server.WillDelay

  @sync_chunk 500
  @scope __MODULE__

  # How long a CONNECT waits for the other nodes to release a session. A
  # node that answers later has its session discarded, not moved.
  @claim_timeout 5_000
  # Within that, how long a node waits for its own connection to let go
  @takeover_timeout 4_000
  # How long a node a session left keeps forwarding to the node it went to,
  # after handing it over: a message reaching the old node later than this
  # behind the new one is missed
  @forward_window 5_000
  # The new node drops duplicates for this long from the claim on: past
  # the claim's deadline and the forwarding that follows it
  @handoff_window @claim_timeout + @forward_window + 5_000
  # Relays per listener per node
  @relays min(System.schedulers_online(), 8)
  # How often hand-off records and cleared retained topics are swept, and
  # how long (s) a clear is remembered
  @sweep_interval 30_000
  @cleared_ttl 3_600

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
  def deliver(listener, id, topic, payload, opts) do
    if clustered?(listener), do: send(relay(listener), {:deliver, id, topic, payload, opts})
    :ok
  end

  @doc false
  # One message for one session that moved to `node`. `message` is
  # `{id, topic, payload, opts, age_ms}`.
  def deliver_to(listener, node, client_id, message) do
    case Enum.find(remote_members(listener), &(node(&1) == node)) do
      nil -> :ok
      pid -> send(relay(listener), {:send, pid, {:deliver_to, client_id, message}})
    end

    :ok
  end

  @doc false
  # This node's relays for a listener
  def relays(listener), do: :persistent_term.get({Relay, listener})

  # The relay this process sends through: always the same one, so what it
  # sends leaves in order
  defp relay(listener) do
    relays = relays(listener)
    elem(relays, :erlang.phash2(self(), tuple_size(relays)))
  end

  @doc false
  # A normal subscription to `segments` came or went on this node
  def route_changed(listener, segments) do
    case :persistent_term.get({Relay, listener}, nil) do
      nil -> :ok
      relays -> send(elem(relays, 0), {:route_changed, segments})
    end

    :ok
  end

  @doc false
  # A session a connection here took over from another node: imported by
  # this node's member, which is where everything forwarded for it arrives —
  # so nothing forwarded lands in the middle of its queue — and fenced: what
  # this node matches for it is held until everything any node sent the old
  # node before the takeover has been forwarded from there. The fence goes
  # out after the routes the import announced.
  def import_moved(listener, client_id, %{from: _} = record) do
    GenServer.call(via(listener), {:import, client_id, record}, 30_000)
  end

  @doc false
  # Deliver what was held for `client_id` now that its fence is down (a
  # process that held a message as the fence came down makes sure of it)
  def release(ctx, client_id) do
    case GenServer.whereis(via(ctx.listener)) do
      pid when pid == self() -> Delivery.release(ctx, client_id)
      nil -> Delivery.release(ctx, client_id)
      pid -> GenServer.call(pid, {:release, client_id})
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  # A shared group's member picked on `node`: this node's member sends it
  # and keeps it until that node says it took it, picking the group's next
  # member if it did not or if the node leaves first
  def deliver_shared(listener, node, client_id, sub_opts, shared) do
    GenServer.cast(via(listener), {:shared_out, node, client_id, sub_opts, shared})
  end

  @doc false
  # Whether other nodes run this listener
  def clustered?(nil), do: false
  def clustered?(listener), do: remote_members(listener) != []

  @doc false
  # Until when (wall-clock ms) a session claimed now drops duplicates
  def handoff_until, do: System.system_time(:millisecond) + @handoff_window

  @doc false
  # A shared subscription came or went on this node
  def shared_changed(listener, op), do: broadcast(listener, {:shared, node(), op})

  @doc false
  # Write a retained message (or clear one) and replicate the write
  def store_retained(listener, table, topic, payload, qos, properties, max) do
    case RetainedStore.write(table, topic, payload, qos, properties, max) do
      {:ok, row} when listener != nil -> broadcast(listener, {:retained, row})
      _ -> :ok
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

    relays =
      for index <- 0..(@relays - 1) do
        {:ok, pid} = Relay.start_link(listener, ctx, index, @relays, self())
        pid
      end

    :persistent_term.put({Relay, listener}, List.to_tuple(relays))

    # `pending`: shared deliveries sent to another node and not yet answered;
    # `fences`: sessions that arrived here, waiting for their fence
    state = %{listener: listener, ctx: ctx, monitor: ref, pending: %{}, fences: %{}}

    # Whoever is already there learns what this node holds (and tells this
    # node what it holds when it sees the join)
    Enum.each(members, &sync_to(&1, state))
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_call({:context, ctx}, _from, state) do
    for pid <- Tuple.to_list(relays(state.listener)), do: GenServer.call(pid, {:context, ctx})
    {:reply, :ok, %{state | ctx: ctx}}
  end

  def handle_call({:import, client_id, %{from: from} = record}, _from, state) do
    ref = make_ref()
    SessionStore.import(state.ctx.sessions, client_id, record, ref)
    send(elem(relays(state.listener), 0), {:fence, ref, client_id, from, self()})
    {:reply, :ok, state}
  end

  def handle_call({:release, client_id}, _from, state) do
    guarded(fn -> Delivery.release(state.ctx, client_id) end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:shared_out, node, client_id, sub_opts, shared}, state) do
    message = Delivery.shared_message(shared, sub_opts)
    {:noreply, send_shared(state, node, client_id, sub_opts, message, false, shared)}
  end

  @impl true
  def handle_info({:deliver, id, topic, payload, opts}, state) do
    guarded(fn -> Delivery.deliver_local(state.ctx, id, topic, payload, opts) end)
    {:noreply, state}
  end

  def handle_info({:deliver_to, client_id, message}, state) do
    guarded(fn -> Delivery.deliver_to(state.ctx, client_id, message) end)
    {:noreply, state}
  end

  def handle_info({:deliver_shared, from, ref, client_id, message, force}, state) do
    result =
      try do
        Delivery.deliver_shared(state.ctx, client_id, message, force)
      rescue
        _ -> :gone
      end

    send(from, {:shared_ack, ref, result})
    {:noreply, state}
  end

  def handle_info({:shared_ack, ref, result}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_pid, _client_id, _sub_opts, _shared}, pending} when result == :ok ->
        {:noreply, %{state | pending: pending}}

      {{pid, client_id, sub_opts, shared}, pending} ->
        shared =
          if result == :offline,
            do: %{shared | offline: shared.offline ++ [{node(pid), client_id, sub_opts}]},
            else: shared

        {:noreply, retry_shared(%{state | pending: pending}, shared)}
    end
  end

  # ---------- Fences ----------

  # On the node a session left: a relay of `node` passed the fence, after
  # everything it sent here before; what this member forwarded for those
  # went ahead through its relay, and so does the answer
  def handle_info({:fence_pass, ref, _client_id, waiter, node, index, count}, state) do
    send(relay(state.listener), {:send, waiter, {:fence_done, ref, node, index, count}})
    {:noreply, state}
  end

  # On the node it arrived at: which nodes' relays to wait for
  def handle_info({:fence_wait, ref, client_id, nodes}, state) do
    Process.send_after(self(), {:fence_timeout, ref}, @forward_window)
    fence = Map.get(state.fences, ref, %{done: %{}, counts: %{}})
    fence = Map.merge(fence, %{client_id: client_id, nodes: nodes})
    {:noreply, check_fence(state, ref, fence)}
  end

  def handle_info({:fence_done, ref, node, index, count}, state) do
    fence = Map.get(state.fences, ref, %{done: %{}, counts: %{}, nodes: nil})

    fence = %{
      fence
      | done: Map.update(fence.done, node, MapSet.new([index]), &MapSet.put(&1, index)),
        counts: Map.put(fence.counts, node, count)
    }

    {:noreply, check_fence(state, ref, fence)}
  end

  # A node that does not answer in time (or the node the session left being
  # slow) holds the session's messages no longer
  def handle_info({:fence_timeout, ref}, state) do
    case Map.pop(state.fences, ref) do
      {%{client_id: client_id}, fences} ->
        {:noreply, lower_fence(%{state | fences: fences}, ref, client_id)}

      {_, fences} ->
        {:noreply, %{state | fences: fences}}
    end
  end

  def handle_info({:claim, reply_to, client_id, mode}, state) do
    # A takeover waits for the connection to let go, and a move forwards for
    # a while after; deliveries meanwhile must not queue up behind either
    ctx = state.ctx
    spawn(fn -> serve_claim(ctx, reply_to, client_id, mode) end)
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

  def handle_info({:retained, row}, state) do
    guarded(fn ->
      RetainedStore.apply_replica(state.ctx.retained_table, row, max_retained(state))
    end)

    {:noreply, state}
  end

  def handle_info({:sync, node, retained, shared}, state) do
    %{retained_table: table, sessions: sessions} = state.ctx
    max = max_retained(state)

    guarded(fn ->
      Enum.each(retained, &RetainedStore.apply_replica(table, &1, max))

      for {segments, group, client_id, opts} <- shared,
          do: SessionStore.put_remote_shared(sessions, node, segments, group, client_id, opts)
    end)

    {:noreply, state}
  end

  # Sessions another node holds, sent when it joined. A client that connected
  # on both sides of a network split keeps the session it began last: the
  # older copy's connection is taken over and the copy dropped, here or
  # there, whichever holds it
  def handle_info({:sessions, _node, began}, state) do
    ctx = state.ctx
    spawn(fn -> drop_older(ctx, began) end)
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

    # A node that left passes every fence
    gone = for pid <- pids, node(pid) != node(), do: node(pid)

    state =
      Enum.reduce(state.fences, state, fn {ref, fence}, state ->
        case fence do
          %{nodes: nodes} when is_list(nodes) ->
            check_fence(state, ref, %{fence | nodes: nodes -- gone})

          _ ->
            state
        end
      end)

    # What was sent to them and not answered goes to another member: it may
    # have been delivered there before they left, it may not
    {lost, pending} = Map.split_with(state.pending, fn {_ref, {pid, _, _, _}} -> pid in pids end)
    state = %{state | pending: pending}

    state =
      Enum.reduce(lost, state, fn {_ref, {_pid, _client_id, _sub_opts, shared}}, state ->
        retry_shared(state, shared)
      end)

    {:noreply, state}
  end

  def handle_info(:flush, state) do
    guarded(fn ->
      SessionStore.sweep(state.ctx.sessions)
      SessionStore.flush(state.ctx.sessions)
    end)

    {:noreply, schedule_flush(state)}
  end

  def handle_info(:sweep, state) do
    # A listener that stopped took its tables along: this member is stale (a
    # restart under the name starts a new one)
    if :ets.info(state.ctx.sessions.sessions) == :undefined do
      {:stop, :normal, state}
    else
      guarded(fn ->
        SessionStore.sweep_seen(state.ctx.sessions)
        RetainedStore.sweep_cleared(state.ctx.retained_table, @cleared_ttl)
      end)

      Process.send_after(self(), :sweep, @sweep_interval)
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    guarded(fn -> SessionStore.flush(state.ctx.sessions) end)
  end

  # The shared subscriptions, the sessions held here, then the retained rows
  # a chunk at a time
  defp sync_to(pid, state) when node(pid) != node() do
    guarded(fn ->
      send(pid, {:sync, node(), [], SessionStore.local_shared(state.ctx.sessions)})

      state.ctx.sessions
      |> SessionStore.began()
      |> Enum.chunk_every(@sync_chunk)
      |> Enum.each(&send(pid, {:sessions, node(), &1}))

      RetainedStore.each_chunk(state.ctx.retained_table, @sync_chunk, fn rows ->
        send(pid, {:sync, node(), rows, []})
      end)
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

  defp check_fence(state, ref, %{nodes: nodes} = fence) when is_list(nodes) do
    passed? =
      Enum.all?(nodes, fn node ->
        count = Map.get(fence.counts, node)
        count != nil and MapSet.size(Map.get(fence.done, node, MapSet.new())) >= count
      end)

    if passed? do
      lower_fence(%{state | fences: Map.delete(state.fences, ref)}, ref, fence.client_id)
    else
      %{state | fences: Map.put(state.fences, ref, fence)}
    end
  end

  defp check_fence(state, ref, fence), do: %{state | fences: Map.put(state.fences, ref, fence)}

  defp lower_fence(state, ref, client_id) do
    guarded(fn ->
      SessionStore.lower_fence(state.ctx.sessions, client_id, ref)
      Delivery.release(state.ctx, client_id)
    end)

    state
  end

  defp send_shared(state, node, client_id, sub_opts, message, force, shared) do
    case Enum.find(remote_members(state.listener), &(node(&1) == node)) do
      nil ->
        retry_shared(state, shared)

      pid ->
        ref = make_ref()
        send(pid, {:deliver_shared, self(), ref, client_id, message, force})
        %{state | pending: Map.put(state.pending, ref, {pid, client_id, sub_opts, shared})}
    end
  end

  defp retry_shared(state, shared) do
    case Delivery.next_shared(state.ctx, shared) do
      {:send, node, client_id, sub_opts, message, force, shared} ->
        send_shared(state, node, client_id, sub_opts, message, force, shared)

      :done ->
        state
    end
  rescue
    e ->
      Logger.debug("[MqttX.Server.Cluster] shared delivery dropped: #{Exception.message(e)}")
      state
  end

  defp max_retained(state), do: Map.get(state.ctx, :max_retained_messages)

  defp schedule_flush(%{ctx: %{sessions: %{backend: nil}}} = state), do: state

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, Map.get(state.ctx, :session_flush_interval, 1_000))
    state
  end

  # On the node that holds the client or its session, for a CONNECT elsewhere
  defp serve_claim(ctx, reply_to, client_id, mode) do
    send(reply_to, {reply_to, answer_claim(ctx, reply_to, client_id, mode)})
  end

  defp answer_claim(ctx, _reply_to, client_id, :peek) do
    if SessionStore.exists?(ctx.sessions, client_id),
      do: {:ok, SessionStore.subscriptions(ctx.sessions, client_id)},
      else: :none
  rescue
    _ -> :none
  end

  defp answer_claim(ctx, reply_to, client_id, mode) do
    take_over_connections(ctx, client_id)
    scope = {ctx.retained_table, client_id}
    WillDelay.cancel(scope)
    SessionExpiry.cancel(scope)

    cond do
      not SessionStore.exists?(ctx.sessions, client_id) ->
        :none

      mode == :clean ->
        SessionStore.delete(ctx.sessions, client_id)
        :none

      true ->
        # Marked first: a message matched from here on is forwarded, not
        # queued behind the export
        to = node(reply_to)
        ref = make_ref()
        SessionStore.mark_moved(ctx.sessions, client_id, to, ref)
        record = SessionStore.export(ctx.sessions, client_id)
        spawn(fn -> finish_move(ctx, client_id, to, ref) end)
        {:ok, Map.put(record, :from, node())}
    end
  rescue
    e ->
      Logger.debug("[MqttX.Server.Cluster] claim failed: #{Exception.message(e)}")
      :none
  end

  defp drop_older(ctx, began) do
    for {client_id, theirs} <- began,
        %{} = meta <- [SessionStore.get(ctx.sessions, client_id)],
        not Map.has_key?(meta, :placeholder),
        not Map.has_key?(meta, :moved_to),
        SessionStore.began_at(meta) < theirs do
      take_over_connections(ctx, client_id)
      scope = {ctx.retained_table, client_id}
      WillDelay.cancel(scope)
      SessionExpiry.cancel(scope)
      SessionStore.delete(ctx.sessions, client_id)
    end
  rescue
    e -> Logger.debug("[MqttX.Server.Cluster] sessions not compared: #{Exception.message(e)}")
  end

  # Forward for a while, then hand over what a fan-out that read the session
  # just before it was marked queued after the export, and let go
  defp finish_move(ctx, client_id, to, ref) do
    Process.sleep(@forward_window)
    now = System.monotonic_time(:millisecond)

    for {topic, payload, opts, queued_at} <-
          SessionStore.finish_move(ctx.sessions, client_id, ref) do
      message = {Map.get(opts, :id), topic, payload, Map.delete(opts, :id), now - queued_at}
      deliver_to(ctx.listener, to, client_id, message)
    end
  rescue
    e -> Logger.debug("[MqttX.Server.Cluster] move not finished: #{Exception.message(e)}")
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
