defmodule MqttX.Client.TopicAliasTest do
  # Regression tests for inbound topic-alias resolution (MQTT 5.0,
  # §3.3.2.3.4): the resolver used to test `is_binary(topic)` although the
  # codec delivers topics as segment lists, so every aliased PUBLISH was
  # delivered with topic "".
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    broker =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)

        {:ok, connack} =
          Codec.encode(5, %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          })

        :ok = :gen_tcp.send(sock, connack)
        send(parent, :broker_ready)

        # Serve send requests scripted by the test process
        serve_loop(sock)
      end)

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: "alias-test",
        protocol_version: 5,
        connect_properties: %{topic_alias_maximum: 10},
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    broker_pid = broker.pid

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      Process.exit(broker_pid, :kill)
      :gen_tcp.close(listen)
    end)

    {:ok, broker: broker}
  end

  defp serve_loop(sock) do
    receive do
      {:send_packet, packet} ->
        :ok = :gen_tcp.send(sock, packet)
        serve_loop(sock)

      :stop ->
        :gen_tcp.close(sock)
    after
      10_000 -> :gen_tcp.close(sock)
    end
  end

  defp broker_send(broker, packet_map) do
    {:ok, data} = Codec.encode(5, packet_map)
    send(broker.pid, {:send_packet, data})
  end

  test "alias-establishing PUBLISH delivers the real topic and stores the mapping", %{
    broker: broker
  } do
    broker_send(broker, %{
      type: :publish,
      topic: "sensors/room1/temp",
      payload: "21.5",
      qos: 0,
      retain: false,
      dup: false,
      properties: %{topic_alias: 1}
    })

    assert_receive {:mqtt_event, :message, {topic, "21.5", _packet}}, 2_000
    assert topic == ["sensors", "room1", "temp"]

    # Alias-only PUBLISH resolves through the stored mapping
    broker_send(broker, %{
      type: :publish,
      topic: "",
      payload: "22.0",
      qos: 0,
      retain: false,
      dup: false,
      properties: %{topic_alias: 1}
    })

    assert_receive {:mqtt_event, :message, {topic2, "22.0", _packet}}, 2_000
    assert topic2 == ["sensors", "room1", "temp"]
  end

  test "unknown alias is a protocol error, not a silent empty topic", %{broker: broker} do
    broker_send(broker, %{
      type: :publish,
      topic: "",
      payload: "x",
      qos: 0,
      retain: false,
      dup: false,
      properties: %{topic_alias: 7}
    })

    refute_receive {:mqtt_event, :message, _}, 500
    assert_receive {:mqtt_event, :disconnected, {:protocol_error, :unknown_topic_alias}}, 2_000
  end
end
