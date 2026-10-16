defmodule MqttX.Client.InboundQosTest do
  @moduledoc """
  The client as the *receiver* of QoS 1 and QoS 2 messages: PUBACK for QoS 1,
  the PUBREC → PUBREL → PUBCOMP exchange for QoS 2 with delivery deferred to
  PUBREL (§4.3.3), the Receive Maximum the client advertised (§3.3.4), and a
  handler that raises mid-delivery.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defmodule RaisingHandler do
    @moduledoc false
    def handle_mqtt_event(:message, {_topic, "boom", _packet}, _state) do
      raise "handler bug"
    end

    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  setup do
    {:ok, broker: FakeBroker.start()}
  end

  defp connect(broker, client_id, opts \\ []) do
    {:ok, client} =
      Connection.start_link(
        Keyword.merge(
          [
            host: "localhost",
            port: broker.port,
            client_id: client_id,
            protocol_version: 5,
            handler: ForwardingHandler,
            handler_state: %{pid: self()}
          ],
          opts
        )
      )

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive {:mqtt_event, :connected, _}, 5_000
    client
  end

  defp publish(topic, payload, qos, packet_id) do
    %{
      type: :publish,
      topic: topic,
      payload: payload,
      qos: qos,
      retain: false,
      dup: false,
      packet_id: packet_id,
      properties: %{}
    }
  end

  defp pubrel(packet_id) do
    %{type: :pubrel, packet_id: packet_id, reason_code: 0, properties: %{}}
  end

  describe "QoS 1" do
    test "a PUBLISH is delivered and acknowledged with PUBACK", %{broker: broker} do
      connect(broker, "rx-qos1")

      FakeBroker.send(broker, publish("rx/q1", "one", 1, 7))

      assert_receive {:mqtt_event, :message, {["rx", "q1"], "one", %{qos: 1, packet_id: 7}}},
                     2_000

      assert_receive {:broker, :packet, %{type: :puback, packet_id: 7}}, 2_000
    end
  end

  describe "QoS 2" do
    test "a PUBLISH is held until PUBREL, then delivered once and completed",
         %{broker: broker} do
      client = connect(broker, "rx-qos2")

      FakeBroker.send(broker, publish("rx/q2", "two", 2, 9))

      assert_receive {:broker, :packet, %{type: :pubrec, packet_id: 9}}, 2_000
      refute_received {:mqtt_event, :message, _}
      assert %{phase: :pubrec_sent} = :sys.get_state(client).pending_acks[{:rx, 9}]

      FakeBroker.send(broker, pubrel(9))

      assert_receive {:mqtt_event, :message, {["rx", "q2"], "two", %{qos: 2}}}, 2_000
      assert_receive {:broker, :packet, %{type: :pubcomp, packet_id: 9}}, 2_000
      refute_receive {:mqtt_event, :message, _}, 100
      assert :sys.get_state(client).pending_acks == %{}
    end

    test "a re-sent PUBLISH for a pending id gets another PUBREC and is still delivered once",
         %{broker: broker} do
      connect(broker, "rx-qos2-dup")

      FakeBroker.send(broker, publish("rx/dup", "d", 2, 11))
      assert_receive {:broker, :packet, %{type: :pubrec, packet_id: 11}}, 2_000

      # The broker did not see our PUBREC and tries again
      FakeBroker.send(broker, %{publish("rx/dup", "d", 2, 11) | dup: true})
      assert_receive {:broker, :packet, %{type: :pubrec, packet_id: 11}}, 2_000

      FakeBroker.send(broker, pubrel(11))
      assert_receive {:mqtt_event, :message, {["rx", "dup"], "d", _}}, 2_000
      refute_receive {:mqtt_event, :message, _}, 100
    end

    test "a PUBREL for an id no longer tracked is answered PUBCOMP 0x92 and delivers nothing",
         %{broker: broker} do
      connect(broker, "rx-qos2-stale")

      # Our PUBCOMP was lost and the broker retransmitted PUBREL (§4.3.3)
      FakeBroker.send(broker, pubrel(42))

      assert_receive {:broker, :packet, %{type: :pubcomp, packet_id: 42, reason_code: 0x92}},
                     2_000

      refute_received {:mqtt_event, :message, _}
    end

    test "a broker exceeding the advertised Receive Maximum gets DISCONNECT 0x93",
         %{broker: broker} do
      connect(broker, "rx-recv-max", connect_properties: %{receive_maximum: 1})

      FakeBroker.send(broker, publish("rx/a", "a", 2, 1))
      assert_receive {:broker, :packet, %{type: :pubrec, packet_id: 1}}, 2_000

      # A second QoS 2 message while the first is still unreleased
      FakeBroker.send(broker, publish("rx/b", "b", 2, 2))

      assert_receive {:broker, :packet, %{type: :disconnect, reason_code: 0x93}}, 2_000

      assert_receive {:mqtt_event, :disconnected, {:protocol_error, :receive_maximum_exceeded}},
                     2_000

      assert_receive {:broker, :closed}, 2_000
      refute_received {:mqtt_event, :message, _}
    end
  end

  describe "a raising handler" do
    test "does not take the connection down, and QoS 1 is still acknowledged",
         %{broker: broker} do
      client = connect(broker, "rx-raise", handler: RaisingHandler)

      log =
        capture_log(fn ->
          FakeBroker.send(broker, publish("rx/r", "boom", 1, 3))
          # A crash before PUBACK would make the broker redeliver the poison
          # message forever
          assert_receive {:broker, :packet, %{type: :puback, packet_id: 3}}, 2_000
        end)

      assert log =~ "raised on :message"
      assert Process.alive?(client)
      assert Connection.connected?(client)

      # ...and later messages still flow
      FakeBroker.send(broker, publish("rx/r", "fine", 0, nil))
      assert_receive {:mqtt_event, :message, {["rx", "r"], "fine", _}}, 2_000
    end
  end
end
