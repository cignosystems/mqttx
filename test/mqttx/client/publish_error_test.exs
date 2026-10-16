defmodule MqttX.Client.PublishErrorTest do
  @moduledoc """
  A broker rejecting one of the client's QoS 1/2 publishes — PUBACK or PUBREC
  with a reason code of 0x80 or above — surfaces to the handler as
  `(:publish_error, {topic, packet_id, reason_code}, state)` and frees the
  in-flight slot. An error PUBREC aborts the QoS 2 flow: no PUBREL (§4.3.3).
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  setup do
    broker = FakeBroker.start()

    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: "publish-error-#{System.unique_integer([:positive])}",
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

    assert_receive {:mqtt_event, :connected, _}, 5_000
    {:ok, broker: broker, client: client}
  end

  test "a PUBACK with an error reason code raises :publish_error and frees the slot",
       %{broker: broker, client: client} do
    :ok = Connection.publish(client, "pe/t", "p", qos: 1)

    assert_receive {:broker, :packet, %{type: :publish, qos: 1, packet_id: id}}, 2_000
    assert :sys.get_state(client).inflight_tx_count == 1

    # 0x87 Not authorized
    FakeBroker.send(broker, %{type: :puback, packet_id: id, reason_code: 0x87, properties: %{}})

    assert_receive {:mqtt_event, :publish_error, {"pe/t", ^id, 0x87}}, 2_000

    state = :sys.get_state(client)
    assert state.pending_acks == %{}
    assert state.inflight_tx_count == 0
  end

  test "a PUBREC with an error reason code aborts the QoS 2 flow without PUBREL",
       %{broker: broker, client: client} do
    :ok = Connection.publish(client, "pe/t2", "p", qos: 2)

    assert_receive {:broker, :packet, %{type: :publish, qos: 2, packet_id: id}}, 2_000

    # 0x97 Quota exceeded
    FakeBroker.send(broker, %{type: :pubrec, packet_id: id, reason_code: 0x97, properties: %{}})

    assert_receive {:mqtt_event, :publish_error, {"pe/t2", ^id, 0x97}}, 2_000
    refute_receive {:broker, :packet, %{type: :pubrel}}, 300

    state = :sys.get_state(client)
    assert state.pending_acks == %{}
    assert state.inflight_tx_count == 0
  end

  test "a successful PUBACK is not an error", %{broker: broker, client: client} do
    :ok = Connection.publish(client, "pe/ok", "p", qos: 1)

    assert_receive {:broker, :packet, %{type: :publish, qos: 1, packet_id: id}}, 2_000
    FakeBroker.send(broker, %{type: :puback, packet_id: id, reason_code: 0, properties: %{}})

    refute_receive {:mqtt_event, :publish_error, _}, 200
    assert :sys.get_state(client).inflight_tx_count == 0
  end
end
