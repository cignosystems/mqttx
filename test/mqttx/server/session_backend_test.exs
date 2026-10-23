defmodule MqttX.Server.SessionBackendTest do
  use ExUnit.Case, async: false

  alias MqttX.Server.SessionBackend.DETS
  alias MqttX.Server.SessionStore
  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  setup do
    dir = Path.join(System.tmp_dir!(), "mqttx_backend_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "sessions.dets")}
  end

  # A backend over a store that can be down, as a database can
  defmodule Flaky do
    @behaviour MqttX.Server.SessionBackend

    def init(_listener, opts), do: {:ok, Keyword.fetch!(opts, :agent)}

    def save(agent, client_id, record) do
      if Agent.get(agent, & &1.down), do: raise("database down")
      Agent.update(agent, &put_in(&1.saved[client_id], record))
    end

    def load(agent, client_id) do
      case Agent.get(agent, & &1.saved[client_id]) do
        nil -> :none
        record -> {:ok, record}
      end
    end

    def delete(agent, client_id) do
      Agent.update(agent, &%{&1 | saved: Map.delete(&1.saved, client_id)})
    end

    def list(agent), do: Agent.get(agent, &Map.to_list(&1.saved))
  end

  defp meta(overrides \\ %{}) do
    Map.merge(
      %{protocol_version: 5, expires_at: :infinity, persistent: true, lifetime: 60},
      overrides
    )
  end

  defp record_for(_client_id) do
    %{meta: meta(), subscriptions: [], inflight: [], queue: [], node: node()}
  end

  describe "SessionStore with a backend" do
    test "a flushed session is restored with its subscriptions, in-flight state and queue",
         %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      :ok = SessionStore.put(store, "c1", meta())
      :ok = SessionStore.subscribe(store, "c1", "a/#", %{qos: 1})
      :ok = SessionStore.put_inflight(store, "c1", {:tx1, 7}, %{type: :publish, packet_id: 7})
      queued_at = System.monotonic_time(:millisecond)
      :ok = SessionStore.enqueue(store, "c1", {"a/b", "hello", %{qos: 1}, queued_at}, nil)
      :ok = SessionStore.flush(store)

      # A new set of tables over the same file, as after a restart
      restarted = SessionStore.new(nil, {DETS, path: path})
      assert SessionStore.restore(restarted) == 1

      # Saved while connected, so its expiry clock starts at the restore
      assert %{expires_at: at} = SessionStore.get(restarted, "c1")
      assert_in_delta at, System.system_time(:second) + 60, 2

      assert [%{filter: "a/#", opts: %{qos: 1}}] = SessionStore.subscriptions(restarted, "c1")
      assert [{{:tx1, 7}, %{packet_id: 7}}] = SessionStore.inflight(restarted, "c1")
      assert [{"c1", %{qos: 1}}] = SessionStore.match(restarted, "a/b")

      assert {:ok, {"a/b", "hello", %{qos: 1}, restored_at}} =
               SessionStore.dequeue(restarted, "c1")

      assert_in_delta restored_at, queued_at, 50
    end

    test "a deleted session is deleted from the backend", %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      :ok = SessionStore.put(store, "gone", meta())
      :ok = SessionStore.flush(store)
      :ok = SessionStore.delete(store, "gone")
      :ok = SessionStore.flush(store)

      assert SessionStore.restore(SessionStore.new(nil, {DETS, path: path})) == 0
    end

    test "an expired session is not restored, and leaves the backend", %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      past = System.system_time(:second) - 10
      :ok = SessionStore.put(store, "old", meta(%{expires_at: past}))
      :ok = SessionStore.flush(store)

      {DETS, table} = store.backend
      assert SessionStore.restore(SessionStore.new(nil, {DETS, path: path})) == 0
      assert DETS.load(table, "old") == :none
    end

    test "a session saved by another node is not restored, but can be loaded", %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      {DETS, table} = store.backend

      record = %{
        meta: meta(),
        subscriptions: [%{filter: "x", opts: %{qos: 0}}],
        inflight: [],
        queue: [],
        node: :other@host
      }

      :ok = DETS.save(table, "elsewhere", record)

      fresh = SessionStore.new(nil, {DETS, path: path})
      assert SessionStore.restore(fresh) == 0
      assert %{subscriptions: [%{filter: "x"}]} = SessionStore.load(fresh, "elsewhere")
    end

    test "a session that moved away, or is on its way here, is left to the node that has it",
         %{path: path} do
      store = SessionStore.new(nil, {DETS, path: path})
      {DETS, table} = store.backend

      # Moved: the record the new node saved in a shared backend stays
      :ok = SessionStore.put(store, "moved", meta())
      :ok = SessionStore.flush(store)
      :ok = DETS.save(table, "moved", %{record_for("moved") | node: :new@host})
      ref = make_ref()
      :ok = SessionStore.mark_moved(store, "moved", :new@host, ref)
      :ok = SessionStore.flush(store)
      assert {:ok, %{node: :new@host}} = DETS.load(table, "moved")

      # Gone from here once the move finishes: still not this node's to delete
      [] = SessionStore.finish_move(store, "moved", ref)
      :ok = SessionStore.flush(store)
      assert {:ok, %{node: :new@host}} = DETS.load(table, "moved")

      # A placeholder is not saved
      :ok = SessionStore.hold(store, "arriving", System.system_time(:millisecond) + 10_000)
      :ok = SessionStore.flush(store)
      assert DETS.load(table, "arriving") == :none
    end

    test "a save that fails leaves the session marked, and the flush goes on next time" do
      {:ok, agent} = Agent.start_link(fn -> %{down: false, saved: %{}} end)
      store = SessionStore.new(nil, {Flaky, agent: agent})
      :ok = SessionStore.put(store, "a", meta())
      :ok = SessionStore.put(store, "b", meta())

      Agent.update(agent, &%{&1 | down: true})
      assert :ok = SessionStore.flush(store)
      assert :ets.info(store.dirty, :size) == 2
      assert Agent.get(agent, & &1.saved) == %{}

      Agent.update(agent, &%{&1 | down: false})
      assert :ok = SessionStore.flush(store)
      assert :ets.info(store.dirty, :size) == 0
      assert Agent.get(agent, & &1.saved) |> Map.keys() |> Enum.sort() == ["a", "b"]
    end

    test "without a backend nothing is tracked or saved" do
      store = SessionStore.new()
      :ok = SessionStore.put(store, "c", meta())
      assert :ets.info(store.dirty, :size) == 0
      assert SessionStore.flush(store) == :ok
      assert SessionStore.restore(store) == 0
    end
  end

  describe "a listener with a backend" do
    defp start(port, path) do
      {:ok, server, owner} =
        ClusterBroker.start_listener(:"backend_#{port}", port,
          session_backend: {DETS, path: path},
          session_flush_interval: 50
        )

      {server, owner}
    end

    defp stop({server, owner}) do
      ThousandIsland.stop(server)
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}
    end

    defp connect(port, opts \\ []) do
      {:ok, client} =
        MqttX.Client.connect(
          [
            host: "127.0.0.1",
            port: port,
            client_id: "durable",
            protocol_version: 5,
            clean_session: false,
            connect_properties: %{session_expiry_interval: 300},
            await_connect: true,
            handler: ForwardingHandler,
            handler_state: %{pid: self()}
          ] ++ opts
        )

      client
    end

    test "sessions and what was queued for them survive a listener restart", %{path: path} do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      listener = start(port, path)
      client = connect(port)
      {:ok, [1]} = MqttX.Client.subscribe(client, "durable/#", qos: 1)
      :ok = MqttX.Client.disconnect(client)
      Process.sleep(100)

      assert {:ok, 1} =
               MqttX.Server.deliver(:"backend_#{port}", "durable/1", "kept", %{qos: 1})

      # Past a flush, then the listener and its tables go away
      Process.sleep(200)
      stop(listener)
      assert :ets.whereis(:"mqttx_#{port}_sessions") == :undefined

      listener = start(port, path)
      client = connect(port)
      assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
      assert_receive {:mqtt_event, :message, {["durable", "1"], "kept", _}}, 3_000

      MqttX.Client.disconnect(client)
      stop(listener)
    end
  end
end
