defmodule MqttX.Server.SessionBackend.ReplicatedTest do
  use ExUnit.Case, async: false

  alias MqttX.Server.SessionBackend.Replicated

  defp record(node \\ node(), expires_at \\ :infinity) do
    %{
      meta: %{protocol_version: 5, expires_at: expires_at, persistent: true, lifetime: 60},
      subscriptions: [],
      inflight: [],
      queue: [],
      node: node
    }
  end

  defp open do
    listener = {:replicated_test, System.unique_integer([:positive])}
    {:ok, state} = Replicated.init(listener, [])
    [peer] = :pg.get_members(MqttX.Server.Cluster, {Replicated, listener})
    {state, peer}
  end

  # A message to the node's process, answered once it has been handled
  defp deliver(peer, message) do
    send(peer, message)
    :sys.get_state(peer)
  end

  test "save, load, list and delete" do
    {state, _peer} = open()
    assert Replicated.load(state, "c") == :none

    :ok = Replicated.save(state, "c", record())
    assert {:ok, %{node: node}} = Replicated.load(state, "c")
    assert node == node()
    assert [{"c", _}] = Replicated.list(state)

    :ok = Replicated.delete(state, "c")
    assert Replicated.load(state, "c") == :none
    assert Replicated.list(state) == []
  end

  test "a save from another node replaces an older version, not a newer one" do
    {state, peer} = open()
    now = System.system_time(:microsecond)

    deliver(peer, {:save, "c", record(:b@host), {now, :b@host}})
    assert {:ok, %{node: :b@host}} = Replicated.load(state, "c")

    deliver(peer, {:save, "c", record(:a@host), {now - 1_000, :a@host}})
    assert {:ok, %{node: :b@host}} = Replicated.load(state, "c")

    # Saved here after that: later than what it replaces, even if this
    # node's clock were behind
    deliver(peer, {:save, "c", record(:b@host), {now + 60_000_000, :b@host}})
    :ok = Replicated.save(state, "c", record())
    assert {:ok, %{node: node}} = Replicated.load(state, "c")
    assert node == node()
  end

  test "only the node that saved a session deletes it, and the delete outlives a late save" do
    {state, peer} = open()
    now = System.system_time(:microsecond)

    deliver(peer, {:save, "c", record(:b@host), {now, :b@host}})
    deliver(peer, {:delete, "c", :a@host, {now + 1, :a@host}})
    assert {:ok, _} = Replicated.load(state, "c")

    deliver(peer, {:delete, "c", :b@host, {now + 2, :b@host}})
    assert Replicated.load(state, "c") == :none

    # A save from before the delete, arriving after it
    deliver(peer, {:save, "c", record(:b@host), {now + 1, :b@host}})
    assert Replicated.load(state, "c") == :none
  end

  test "a node joining is sent what the others hold" do
    {state, peer} = open()
    now = System.system_time(:microsecond)

    deliver(peer, {:sync, [{"x", record(:b@host), {now, :b@host}}, {"y", nil, {now, :b@host}}]})
    assert {:ok, _} = Replicated.load(state, "x")
    assert Replicated.load(state, "y") == :none
  end

  test "a sweep forgets expired sessions and old deletes, and nothing else" do
    {state, peer} = open()
    now_us = System.system_time(:microsecond)
    hour = 3_600 * 1_000_000

    deliver(
      peer,
      {:save, "expired", record(:b@host, System.system_time(:second) - 1), {now_us, :b@host}}
    )

    deliver(
      peer,
      {:save, "live", record(:b@host, System.system_time(:second) + 300), {now_us, :b@host}}
    )

    deliver(peer, {:save, "connected", record(:b@host), {now_us, :b@host}})

    # Deleted two hours ago, and one deleted just now
    deliver(peer, {:save, "old-delete", record(:b@host), {now_us - 3 * hour, :b@host}})
    deliver(peer, {:delete, "old-delete", :b@host, {now_us - 2 * hour, :b@host}})
    deliver(peer, {:save, "new-delete", record(:b@host), {now_us, :b@host}})
    deliver(peer, {:delete, "new-delete", :b@host, {now_us + 1, :b@host}})

    deliver(peer, :sweep)

    table = state.table
    assert :ets.lookup(table, "expired") == []
    assert :ets.lookup(table, "old-delete") == []
    assert [{"live", _, _}] = :ets.lookup(table, "live")
    assert [{"connected", _, _}] = :ets.lookup(table, "connected")
    # Still remembered, so a late save cannot bring it back
    assert [{"new-delete", nil, _}] = :ets.lookup(table, "new-delete")
  end

  test "sessions saved while connected on a node that leaves start their expiry clock" do
    {state, peer} = open()
    now = System.system_time(:microsecond)

    deliver(peer, {:save, "gone", record(:b@host), {now, :b@host}})
    deliver(peer, {:save, "other", record(:c@host), {now, :c@host}})

    ref = :sys.get_state(peer).monitor
    deliver(peer, {ref, :leave, {Replicated, :x}, [remote_pid(:b@host)]})

    assert {:ok, %{meta: %{expires_at: expires_at}}} = Replicated.load(state, "gone")
    assert is_integer(expires_at) and expires_at > System.system_time(:second)
    assert {:ok, %{meta: %{expires_at: :infinity}}} = Replicated.load(state, "other")
  end

  # A pid of another node, built from its external term format
  defp remote_pid(node) do
    name = Atom.to_string(node)
    :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, 1::32, 0::32, 1::32>>)
  end
end
