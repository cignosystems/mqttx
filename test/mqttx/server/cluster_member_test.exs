defmodule MqttX.Server.ClusterMemberTest do
  @moduledoc """
  The listener's member process on one node: a late fence answer keeps no
  state, and a member that starts again holds nothing back for fences it
  was not waiting on.
  """
  use ExUnit.Case, async: false

  alias MqttX.Server.Cluster
  alias MqttX.Server.SessionStore
  alias MqttX.Test.ClusterBroker

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    name = :"member_#{port}"
    {:ok, server, owner} = ClusterBroker.start_listener(name, port)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {:ok, name: name}
  end

  defp member(name) do
    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    member
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "a fence answer for a fence that is down is dropped", %{name: name} do
    member = member(name)
    send(member, {:fence_done, make_ref(), node(), 0, 1})
    assert :sys.get_state(member).fences == %{}
  end

  test "a member starting again lowers the fences it finds and lets held messages out", %{
    name: name
  } do
    member = member(name)
    sessions = :sys.get_state(member).ctx.sessions

    :ok =
      SessionStore.put(sessions, "fenced", %{
        protocol_version: 5,
        expires_at: :infinity,
        persistent: true
      })

    :ets.insert(sessions.sessions, {{:fence, "fenced"}, make_ref()})
    held = {make_ref(), "t", "held", %{qos: 1}, System.monotonic_time(:millisecond)}
    :ok = SessionStore.hold_message(sessions, "fenced", held)
    assert SessionStore.fenced?(sessions, "fenced")

    Process.exit(member, :kill)
    wait_until(fn -> match?([_], Cluster.members(name)) and member(name) != member end)

    refute SessionStore.fenced?(sessions, "fenced")
    # Released into the session's queue, where a reconnecting client finds it
    wait_until(fn -> :ets.info(sessions.held, :size) == 0 end)
    assert {:ok, {"t", "held", _opts, _at}} = SessionStore.dequeue(sessions, "fenced")
  end
end
