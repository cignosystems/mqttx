defmodule MqttX.Server.Cluster.Relay do
  @moduledoc false

  # What one node of a listener's group sends the others, in order.
  #
  # A process on this node hands its deliveries for other nodes to one relay
  # (picked by its pid), so its messages leave in the order it sent them
  # whichever node they go to. Each listener has a few relays per node,
  # started and stopped with its MqttX.Server.Cluster member.
  #
  # Relay 0 also keeps the route table. It tells relay 0 on every other node
  # which subscription filters this node has (`{:route, ...}` when one comes
  # or goes, `{:routes, ...}` when a relay 0 joins), and writes theirs into
  # the store's `routes` table; a delivery goes only to the nodes with a
  # filter matching its topic — every node, until that node's routes have
  # arrived. A fence (MqttX.Server.Cluster.fence/4) goes through relay 0
  # too, after the routes it depends on, and from there to every relay.

  use GenServer

  require Logger

  alias MqttX.Server.SessionStore

  @scope MqttX.Server.Cluster

  def start_link(listener, ctx, index, count, member) do
    GenServer.start_link(__MODULE__, {listener, ctx, index, count, member})
  end

  # Relay 0 of each node is in this group
  def group(listener), do: {listener, :relay}

  @impl true
  def init({listener, ctx, index, count, member}) do
    Process.monitor(member)
    state = %{listener: listener, ctx: ctx, index: index, count: count, announced: MapSet.new()}

    if index == 0 do
      :ok = :pg.join(@scope, group(listener), self())
      {ref, others} = :pg.monitor(@scope, group(listener))
      state = Map.merge(state, %{monitor: ref, announced: present_filters(ctx)})
      Enum.each(others, &sync_routes(&1, state))
      {:ok, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:context, ctx}, _from, state), do: {:reply, :ok, %{state | ctx: ctx}}

  @impl true
  def handle_info({:deliver, id, topic, payload, opts}, state) do
    guarded(fn ->
      message = {:deliver, id, topic, payload, opts}
      routed = SessionStore.route_nodes(state.ctx.sessions, topic)

      for pid <- remote_members(state.listener),
          node = node(pid),
          MapSet.member?(routed, node) or
            not SessionStore.routes_synced?(state.ctx.sessions, node),
          do: send(pid, message)
    end)

    {:noreply, state}
  end

  def handle_info({:send, pid, message}, state) do
    send(pid, message)
    {:noreply, state}
  end

  # ---------- Relay 0: routes ----------

  # A filter of this node may have come or gone: say what it is now
  def handle_info({:route_changed, segments}, state) do
    present = guarded(fn -> SessionStore.route?(state.ctx.sessions, segments) end, false)

    cond do
      present == MapSet.member?(state.announced, segments) ->
        {:noreply, state}

      true ->
        Enum.each(remote_relays(state.listener), &send(&1, {:route, node(), segments, present}))

        announced =
          if present,
            do: MapSet.put(state.announced, segments),
            else: MapSet.delete(state.announced, segments)

        {:noreply, %{state | announced: announced}}
    end
  end

  def handle_info({:route, node, segments, present}, state) do
    guarded(fn -> SessionStore.put_route(state.ctx.sessions, node, segments, present) end)
    {:noreply, state}
  end

  def handle_info({:routes, node, filters}, state) do
    guarded(fn -> SessionStore.replace_routes(state.ctx.sessions, node, filters) end)
    {:noreply, state}
  end

  def handle_info({ref, :join, _group, pids}, %{monitor: ref} = state) do
    Enum.each(pids, &sync_routes(&1, state))
    {:noreply, state}
  end

  def handle_info({ref, :leave, _group, pids}, %{monitor: ref} = state) do
    # Unless the node's relay 0 restarted and its routes arrived already
    still_there = MapSet.new(remote_relays(state.listener), &node/1)

    for pid <- pids, node(pid) != node(), not MapSet.member?(still_there, node(pid)) do
      guarded(fn -> SessionStore.drop_routes(state.ctx.sessions, node(pid)) end)
    end

    {:noreply, state}
  end

  # ---------- Fences ----------

  # From a connection on this node that just took a session over from
  # `from`: every relay of every node passes the fence on to `from`'s member
  def handle_info({:fence, ref, client_id, from, waiter}, state) do
    others = remote_relays(state.listener)
    send(waiter, {:fence_wait, ref, client_id, [node() | Enum.map(others, &node/1)]})
    Enum.each(others, &send(&1, {:fence_out, ref, client_id, from, waiter}))
    handle_info({:fence_out, ref, client_id, from, waiter}, state)
  end

  # Relay 0 here: after the routes the fence's sender announced before it,
  # to this node's other relays and through itself
  def handle_info({:fence_out, ref, client_id, from, waiter}, %{index: 0} = state) do
    for pid <- siblings(state.listener), pid != self() do
      send(pid, {:fence_pass, ref, client_id, from, waiter})
    end

    handle_info({:fence_pass, ref, client_id, from, waiter}, state)
  end

  # Whatever this relay sent `from` before goes ahead of the fence
  def handle_info({:fence_pass, ref, client_id, from, waiter}, state) do
    pass = {:fence_pass, ref, client_id, waiter, node(), state.index, state.count}

    case Enum.find(MqttX.Server.Cluster.members(state.listener), &(node(&1) == from)) do
      nil -> send(waiter, {:fence_done, ref, node(), state.index, state.count})
      pid -> send(pid, pass)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ---------- Helpers ----------

  defp sync_routes(pid, state) when node(pid) != node() do
    send(pid, {:routes, node(), MapSet.to_list(state.announced)})
  end

  defp sync_routes(_pid, _state), do: :ok

  defp present_filters(ctx) do
    guarded(fn -> MapSet.new(SessionStore.route_filters(ctx.sessions)) end, MapSet.new())
  end

  defp remote_members(listener) do
    for pid <- MqttX.Server.Cluster.members(listener), node(pid) != node(), do: pid
  end

  defp remote_relays(listener) do
    for pid <- :pg.get_members(@scope, group(listener)), node(pid) != node(), do: pid
  end

  defp siblings(listener), do: MqttX.Server.Cluster.relays(listener) |> Tuple.to_list()

  defp guarded(fun, default \\ :ok) do
    fun.()
  rescue
    e ->
      Logger.debug("[MqttX.Server.Cluster.Relay] skipped: #{Exception.message(e)}")
      default
  end
end
