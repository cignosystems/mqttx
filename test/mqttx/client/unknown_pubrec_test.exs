defmodule MqttX.Client.UnknownPubrecTest do
  @moduledoc """
  A PUBREC for a packet id the client is not tracking (the broker's half of a
  QoS 2 flow the client has already forgotten). §3.6.2.1 lets the sender
  answer PUBREL 0x92 (Packet Identifier not found) so the receiver can clean
  up — which the client does on MQTT 5.0, mirroring the broker's handling of
  an unknown PUBREL. Pre-5 PUBREL has no reason code, so a v4 client stays
  silent as before. Either way the real in-flight state is untouched.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defp connect(broker, version) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: "unknown-pubrec-#{System.unique_integer([:positive])}",
        protocol_version: version,
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
    client
  end

  test "v5: an unknown PUBREC is answered with PUBREL 0x92 and nothing else changes" do
    broker = FakeBroker.start()
    client = connect(broker, 5)

    # One genuine QoS 2 flow in progress, to show it is left alone
    :ok = Connection.publish(client, "q2/t", "p", qos: 2)
    assert_receive {:broker, :packet, %{type: :publish, qos: 2, packet_id: real}}, 2_000
    assert :sys.get_state(client).inflight_tx_count == 1

    FakeBroker.send(broker, %{type: :pubrec, packet_id: 4242, reason_code: 0, properties: %{}})

    assert_receive {:broker, :packet, %{type: :pubrel, packet_id: 4242, reason_code: 0x92}},
                   2_000

    # The broker completes its side; that PUBCOMP matches no entry of ours
    FakeBroker.send(broker, %{type: :pubcomp, packet_id: 4242, reason_code: 0, properties: %{}})
    # Sync point: the PINGRESP is processed after the PUBCOMP
    FakeBroker.send(broker, %{type: :pingresp})
    Process.sleep(50)

    state = :sys.get_state(client)
    assert state.inflight_tx_count == 1
    assert %{phase: :pubrec_pending} = state.pending_acks[{:tx, real}]
    assert Connection.connected?(client)
  end

  test "v4: an unknown PUBREC is ignored (PUBREL carries no reason code)" do
    broker = FakeBroker.start()
    client = connect(broker, 4)

    FakeBroker.send(broker, %{type: :pubrec, packet_id: 4242})

    refute_receive {:broker, :packet, %{type: :pubrel}}, 300
    assert Connection.connected?(client)
  end
end
