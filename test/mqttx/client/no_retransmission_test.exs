defmodule MqttX.Client.NoRetransmissionTest do
  @moduledoc """
  MQTT §4.4: an unacknowledged QoS 1/2 PUBLISH or PUBREL is re-sent only when
  a session is resumed — "Clients and Servers MUST NOT resend messages at any
  other time" [MQTT-4.4.0-1]. On a live connection the client holds the
  message until the broker answers; it neither re-sends nor gives up. The
  pre-0.12 `:retry_interval` option is accepted, warned about and ignored.
  The resumption re-send itself is covered by `inflight_resend_test.exs`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  setup do
    broker = FakeBroker.start()
    test = self()

    {client, log} =
      with_log(fn ->
        {:ok, client} =
          Connection.start_link(
            host: "localhost",
            port: broker.port,
            client_id: "no-retry-#{System.unique_integer([:positive])}",
            protocol_version: 5,
            # Deprecated — and small enough that the old timer would have fired
            # several times within these tests
            retry_interval: 50,
            handler: ForwardingHandler,
            handler_state: %{pid: test}
          )

        client
      end)

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive {:mqtt_event, :connected, _}, 5_000
    {:ok, broker: broker, client: client, log: log}
  end

  test "passing :retry_interval logs a deprecation warning", %{log: log} do
    assert log =~ ":retry_interval is deprecated and ignored since 0.12.0"
  end

  test "an unacknowledged QoS 1 PUBLISH is held, not re-sent or dropped",
       %{broker: broker, client: client} do
    :ok = Connection.publish(client, "hold/q1", "p", qos: 1)

    assert_receive {:broker, :packet, %{type: :publish, qos: 1, dup: false, packet_id: id}},
                   2_000

    refute_receive {:broker, :packet, _}, 300
    assert %{phase: :puback_pending} = :sys.get_state(client).pending_acks[{:tx, id}]

    # A late PUBACK completes it normally: no :publish_error, slot freed
    FakeBroker.send(broker, %{type: :puback, packet_id: id, reason_code: 0, properties: %{}})

    refute_receive {:mqtt_event, :publish_error, _}, 200
    state = :sys.get_state(client)
    assert state.pending_acks == %{}
    assert state.inflight_tx_count == 0
  end

  test "an outbound QoS 2 flow waiting for PUBCOMP does not re-send PUBREL",
       %{broker: broker, client: client} do
    :ok = Connection.publish(client, "hold/q2", "p", qos: 2)
    assert_receive {:broker, :packet, %{type: :publish, qos: 2, packet_id: id}}, 2_000

    FakeBroker.send(broker, %{type: :pubrec, packet_id: id, reason_code: 0, properties: %{}})
    assert_receive {:broker, :packet, %{type: :pubrel, packet_id: ^id}}, 2_000

    refute_receive {:broker, :packet, _}, 300
    assert %{phase: :pubcomp_pending} = :sys.get_state(client).pending_acks[{:tx, id}]
  end
end
