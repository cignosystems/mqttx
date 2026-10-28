defmodule MqttX.Server.SessionStoreLimitsTest do
  @moduledoc """
  The session store's answers to the listener's caps and its backend: the
  `:max_sessions` count that is not a scan of the table per CONNECT, and
  the sessions that end with their connection, which a backend never sees.
  """
  use ExUnit.Case, async: true

  alias MqttX.Server.SessionBackend.DETS
  alias MqttX.Server.SessionStore

  defp meta(overrides \\ %{}) do
    Map.merge(
      %{protocol_version: 5, expires_at: :infinity, persistent: true, lifetime: 60},
      overrides
    )
  end

  describe "admit?/2" do
    test "admits up to the cap, holds it through a burst, and sees a session end at once" do
      store = SessionStore.new()

      for client <- ["a", "b", "c"] do
        assert SessionStore.admit?(store, 3)
        :ok = SessionStore.put(store, client, meta())
      end

      # The count it keeps says no, and so does a fresh one
      refute SessionStore.admit?(store, 3)
      refute SessionStore.admit?(store, 3)

      # A session gone frees its place before the kept count is refreshed
      :ok = SessionStore.delete(store, "b")
      assert SessionStore.admit?(store, 3)
      :ok = SessionStore.put(store, "d", meta())
      refute SessionStore.admit?(store, 3)
    end

    test "placeholders and what a moved session left do not count" do
      store = SessionStore.new()
      :ok = SessionStore.hold(store, "arriving", System.system_time(:millisecond) + 10_000)
      :ok = SessionStore.put(store, "gone", meta())
      :ok = SessionStore.mark_moved(store, "gone", :other@host, make_ref())

      assert SessionStore.count(store) == 0
      assert SessionStore.admit?(store, 1)
    end
  end

  describe "a session that ends with its connection" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mqttx_limits_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: Path.join(dir, "sessions.dets")}
    end

    test "is never saved to the backend", %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      {DETS, table} = store.backend

      :ok = SessionStore.put(store, "brief", meta(%{persistent: false, lifetime: 0}))
      :ok = SessionStore.subscribe(store, "brief", "a/#", %{qos: 1})
      :ok = SessionStore.enqueue(store, "brief", {"a/b", "x", %{qos: 1}, 0}, nil)
      assert :ets.info(store.dirty, :size) == 0

      :ok = SessionStore.flush(store)
      assert DETS.load(table, "brief") == :none

      :ok = SessionStore.delete(store, "brief")
      assert :ets.info(store.dirty, :size) == 0
    end

    test "connecting before the restore of its saved record has the record reconciled",
         %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      {DETS, table} = store.backend

      for client <- ["brief", "kept"] do
        :ok = SessionStore.put(store, client, meta())
        :ok = SessionStore.subscribe(store, client, "old/#{client}", %{qos: 1})
      end

      :ok = SessionStore.flush(store)

      # New tables over the same file, and both clients connect before the
      # restore runs: one with Clean Start 1 (a session that ends with its
      # connection), one resuming with a new subscription
      restarted = SessionStore.new(nil, {DETS, path: path})
      :ok = SessionStore.put(restarted, "brief", meta(%{persistent: false, lifetime: 0}))
      :ok = SessionStore.put(restarted, "kept", meta())
      :ok = SessionStore.subscribe(restarted, "kept", "new/kept", %{qos: 1})

      assert SessionStore.restore(restarted) == 0
      assert SessionStore.subscriptions(restarted, "brief") == []
      assert [%{filter: "new/kept"}] = SessionStore.subscriptions(restarted, "kept")

      :ok = SessionStore.flush(restarted)
      assert DETS.load(table, "brief") == :none
      assert {:ok, %{subscriptions: [%{filter: "new/kept"}]}} = DETS.load(table, "kept")

      # So a third start brings back only what is still a session
      third = SessionStore.new(nil, {DETS, path: path})
      assert SessionStore.restore(third) == 1
      assert SessionStore.get(third, "brief") == nil
      assert [%{filter: "new/kept"}] = SessionStore.subscriptions(third, "kept")
    end

    test "replacing a saved one has it deleted from the backend", %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      {DETS, table} = store.backend

      :ok = SessionStore.put(store, "c", meta())
      :ok = SessionStore.flush(store)
      assert {:ok, _} = DETS.load(table, "c")

      # Back with Clean Start 1, or a Session Expiry Interval of 0
      :ok = SessionStore.put(store, "c", meta(%{persistent: false, lifetime: 0}))
      :ok = SessionStore.flush(store)
      assert DETS.load(table, "c") == :none

      # And a persistent one again: saved again
      :ok = SessionStore.put(store, "c", meta())
      :ok = SessionStore.flush(store)
      assert {:ok, %{meta: %{persistent: true}}} = DETS.load(table, "c")
    end
  end
end
