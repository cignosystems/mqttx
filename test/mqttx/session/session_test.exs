defmodule MqttX.Session.StoreTest do
  use ExUnit.Case, async: true

  alias MqttX.Session.ETSStore

  describe "ETSStore.init/1" do
    test "initializes with default table name" do
      {:ok, state} = ETSStore.init([])
      assert state.table == :mqttx_sessions
    end

    test "initializes with custom table name" do
      table_name = :"custom_session_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETSStore.init(table: table_name)
      assert state.table == table_name
    end
  end

  describe "ETSStore.save/3 and load/2" do
    setup do
      table_name = :"session_test_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETSStore.init(table: table_name)
      {:ok, state: state}
    end

    test "saves and loads session data", %{state: state} do
      client_id = "test-client-1"

      session_data = %{
        subscriptions: %{"topic/a" => 1, "topic/b" => 0},
        pending_acks: %{{:tx, 1} => %{phase: :puback_pending}},
        packet_id: 42
      }

      :ok = ETSStore.save(client_id, session_data, state)
      {:ok, loaded} = ETSStore.load(client_id, state)

      assert loaded == session_data
    end

    test "returns :not_found for non-existent client", %{state: state} do
      assert :not_found = ETSStore.load("non-existent-client", state)
    end

    test "overwrites existing session data", %{state: state} do
      client_id = "test-client-2"
      data1 = %{subscriptions: %{"topic/a" => 0}}
      data2 = %{subscriptions: %{"topic/b" => 1}}

      :ok = ETSStore.save(client_id, data1, state)
      :ok = ETSStore.save(client_id, data2, state)

      {:ok, loaded} = ETSStore.load(client_id, state)
      assert loaded == data2
    end
  end

  describe "ETSStore.delete/2" do
    setup do
      table_name = :"session_delete_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETSStore.init(table: table_name)
      {:ok, state: state}
    end

    test "deletes existing session", %{state: state} do
      client_id = "test-client-delete"
      session_data = %{subscriptions: %{}}

      :ok = ETSStore.save(client_id, session_data, state)
      :ok = ETSStore.delete(client_id, state)

      assert :not_found = ETSStore.load(client_id, state)
    end

    test "succeeds even if session doesn't exist", %{state: state} do
      :ok = ETSStore.delete("non-existent-client", state)
    end
  end

  describe "ETSStore with complex session data" do
    setup do
      table_name = :"session_complex_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETSStore.init(table: table_name)
      {:ok, state: state}
    end

    test "preserves all session fields", %{state: state} do
      client_id = "complex-client"

      session_data = %{
        subscriptions: %{
          "sensors/+/temp" => 1,
          "alerts/#" => 2,
          "status" => 0
        },
        pending_acks: %{
          {:tx, 1} => %{phase: :puback_pending, packet: %{type: :publish}, timestamp: 12345},
          {:tx, 2} => %{phase: :pubrec_pending, packet: %{type: :publish}, timestamp: 12346},
          {:rx, 3} => %{phase: :pubrec_sent, packet: %{type: :publish}}
        },
        packet_id: 100
      }

      :ok = ETSStore.save(client_id, session_data, state)
      {:ok, loaded} = ETSStore.load(client_id, state)

      assert loaded.subscriptions == session_data.subscriptions
      assert loaded.pending_acks == session_data.pending_acks
      assert loaded.packet_id == session_data.packet_id
    end

    test "handles multiple clients independently", %{state: state} do
      client1_data = %{subscriptions: %{"topic/1" => 0}, packet_id: 10}
      client2_data = %{subscriptions: %{"topic/2" => 1}, packet_id: 20}

      :ok = ETSStore.save("client-1", client1_data, state)
      :ok = ETSStore.save("client-2", client2_data, state)

      {:ok, loaded1} = ETSStore.load("client-1", state)
      {:ok, loaded2} = ETSStore.load("client-2", state)

      assert loaded1 == client1_data
      assert loaded2 == client2_data
    end
  end

  describe "expiry sweep" do
    setup do
      table_name = :"session_sweep_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETSStore.init(table: table_name)
      {:ok, state: state, table: table_name}
    end

    test "sweep_expired/2 deletes only records whose expires_at has passed",
         %{state: state, table: table} do
      now = 1_000_000

      :ok = ETSStore.save("expired", %{packet_id: 1, expires_at: now - 1}, state)
      :ok = ETSStore.save("expiring-now", %{packet_id: 2, expires_at: now}, state)
      :ok = ETSStore.save("future", %{packet_id: 3, expires_at: now + 1}, state)
      :ok = ETSStore.save("never", %{packet_id: 4, expires_at: nil}, state)
      :ok = ETSStore.save("legacy", %{packet_id: 5}, state)

      assert ETSStore.sweep_expired(table, now) == 2

      assert :not_found = ETSStore.load("expired", state)
      assert :not_found = ETSStore.load("expiring-now", state)
      assert {:ok, _} = ETSStore.load("future", state)
      assert {:ok, _} = ETSStore.load("never", state)
      assert {:ok, _} = ETSStore.load("legacy", state)
    end

    test "ETSOwner sweeps every table it owns", %{state: state} do
      past = System.system_time(:second) - 60
      :ok = ETSStore.save("stale", %{packet_id: 1, expires_at: past}, state)
      :ok = ETSStore.save("fresh", %{packet_id: 2, expires_at: past + 3_600}, state)

      # Tables created through ETSStore.init/1 are registered with the owner
      assert MqttX.Session.ETSOwner.sweep_now() >= 1

      assert :not_found = ETSStore.load("stale", state)
      assert {:ok, _} = ETSStore.load("fresh", state)
    end
  end
end
