defmodule MqttX.Client.ConnackLimitsTest do
  @moduledoc """
  The CONNACK limits a client MUST honour on its own PUBLISHes: Maximum QoS
  (§3.2.2.3.4, MQTT-3.2.2-11) and Retain Available (§3.2.2.3.5,
  MQTT-3.2.2-14). A publish that would break either is refused at the API
  with a distinct error instead of being clamped or sent — the broker would
  otherwise answer with DISCONNECT 0x9B / 0x9A and the client would
  reconnect-loop. Both are per-connection settings, reset on every CONNACK.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defp start_client(broker, client_id) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: client_id,
        protocol_version: 5,
        handler: ForwardingHandler,
        handler_state: %{pid: self()}
      )

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  defp connack(properties) do
    %{type: :connack, session_present: false, reason_code: 0, properties: properties}
  end

  describe "a broker advertising maximum_qos: 1 and retain_available: false" do
    setup do
      broker = FakeBroker.start(connack: connack(%{maximum_qos: 1, retain_available: false}))
      client = start_client(broker, "connack-limits-#{System.unique_integer([:positive])}")
      assert_receive {:mqtt_event, :connected, %{properties: %{maximum_qos: 1}}}, 5_000
      {:ok, broker: broker, client: client}
    end

    test "both limits are recorded from the CONNACK", %{client: client} do
      state = :sys.get_state(client)
      assert state.server_maximum_qos == 1
      assert state.server_retain_available == false
    end

    test "a publish above the Maximum QoS is refused, not clamped or sent (MQTT-3.2.2-11)",
         %{client: client} do
      assert {:error, :qos_not_supported} = Connection.publish(client, "lim/t", "p", qos: 2)

      refute_receive {:broker, :packet, %{type: :publish}}, 200
      assert :sys.get_state(client).inflight_tx_count == 0
      assert Connection.connected?(client)
    end

    test "publishes at or below the Maximum QoS go through", %{client: client} do
      assert :ok = Connection.publish(client, "lim/t", "p", qos: 1)
      assert_receive {:broker, :packet, %{type: :publish, qos: 1}}, 2_000

      assert :ok = Connection.publish(client, "lim/t", "p", qos: 0)
      assert_receive {:broker, :packet, %{type: :publish, qos: 0}}, 2_000
    end

    test "a retained publish is refused when Retain Available is 0 (MQTT-3.2.2-14)",
         %{client: client} do
      assert {:error, :retain_not_supported} =
               Connection.publish(client, "lim/t", "p", retain: true)

      refute_receive {:broker, :packet, %{type: :publish}}, 200
      assert Connection.connected?(client)

      # Without RETAIN the same publish is fine
      assert :ok = Connection.publish(client, "lim/t", "p", retain: false)
      assert_receive {:broker, :packet, %{type: :publish, retain: false}}, 2_000
    end

    test "the QoS check runs before the retain check", %{client: client} do
      assert {:error, :qos_not_supported} =
               Connection.publish(client, "lim/t", "p", qos: 2, retain: true)
    end
  end

  describe "a broker that omits both properties" do
    test "QoS 2 and retain are allowed (the spec defaults)" do
      broker = FakeBroker.start()
      client = start_client(broker, "connack-defaults-#{System.unique_integer([:positive])}")
      assert_receive {:mqtt_event, :connected, _}, 5_000

      state = :sys.get_state(client)
      assert state.server_maximum_qos == 2
      assert state.server_retain_available == true

      assert :ok = Connection.publish(client, "lim/t", "p", qos: 2, retain: true)
      assert_receive {:broker, :packet, %{type: :publish, qos: 2, retain: true}}, 2_000
    end
  end

  test "the limits are reset by the next CONNACK, not carried across connections" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "connack-reset-#{System.unique_integer([:positive])}")

    # First connection: restrictive broker
    assert_receive {:broker, :connect, _}, 2_000
    FakeBroker.send(broker, connack(%{maximum_qos: 0, retain_available: false}))
    assert_receive {:mqtt_event, :connected, _}, 5_000
    assert {:error, :qos_not_supported} = Connection.publish(client, "lim/t", "p", qos: 1)

    assert {:error, :retain_not_supported} =
             Connection.publish(client, "lim/t", "p", retain: true)

    # Drop the connection; the client reconnects and the new CONNACK carries
    # no limits at all
    FakeBroker.close(broker)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    assert_receive {:broker, :connect, _}, 10_000
    FakeBroker.send(broker, connack(%{}))
    assert_receive {:mqtt_event, :connected, _}, 5_000

    assert :ok = Connection.publish(client, "lim/t", "p", qos: 2, retain: true)
    assert_receive {:broker, :packet, %{type: :publish, qos: 2, retain: true}}, 2_000
  end
end
