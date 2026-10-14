defmodule MqttX.Client.CodecPublishTest do
  @moduledoc """
  `MqttX.Client.publish/4` with `codec:` encodes the term and carries the
  codec's Payload Format Indicator and Content Type on the wire.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  # Accept one connection, answer CONNACK, then decode every packet the
  # client sends and forward it to the test process
  defp start_broker(listen, version) do
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)

      {:ok, connack} =
        Codec.encode(version, %{type: :connack, session_present: false, reason_code: 0})

      :ok = :gen_tcp.send(sock, connack)
      relay(sock, version, parent, <<>>)
    end)
  end

  defp relay(sock, version, parent, buffer) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        buffer = decode_all(version, buffer <> data, parent)
        relay(sock, version, parent, buffer)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp decode_all(version, buffer, parent) do
    case Codec.decode(version, buffer) do
      {:ok, {packet, rest}} ->
        send(parent, {:broker_got, packet})
        decode_all(version, rest, parent)

      {:error, :incomplete} ->
        buffer
    end
  end

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)
    {:ok, listen: listen, port: port}
  end

  defp connect(ctx, version) do
    start_broker(ctx.listen, version)

    {:ok, client} =
      MqttX.Client.connect(
        host: "localhost",
        port: ctx.port,
        client_id: "codec-#{version}",
        protocol_version: version,
        await_connect: true,
        handler: Forwarder,
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

  @tag :json
  test "the term is encoded and the codec's properties are sent (MQTT 5.0)", ctx do
    client = connect(ctx, 5)

    assert :ok =
             MqttX.Client.publish(client, "sensors/room1", %{temp: 21.5},
               qos: 1,
               codec: MqttX.Payload.JSON,
               properties: %{message_expiry_interval: 60}
             )

    assert_receive {:broker_got, %{type: :publish} = pub}, 5_000
    assert pub.payload == ~s({"temp":21.5})
    assert pub.qos == 1
    assert pub.properties.payload_format_indicator == true
    assert pub.properties.content_type == "application/json"
    assert pub.properties.message_expiry_interval == 60
  end

  @tag :json
  test "an explicit property wins over the codec's metadata", ctx do
    client = connect(ctx, 5)

    assert :ok =
             MqttX.Client.publish(client, "t", [1],
               codec: MqttX.Payload.JSON,
               properties: %{content_type: "application/vnd.acme+json"}
             )

    assert_receive {:broker_got, %{type: :publish} = pub}, 5_000
    assert pub.properties.content_type == "application/vnd.acme+json"
    assert pub.properties.payload_format_indicator == true
  end

  @tag :json
  test "with MQTT 3.1.1 the term is still encoded; properties do not exist on the wire", ctx do
    client = connect(ctx, 4)

    assert :ok = MqttX.Client.publish(client, "t", %{a: 1}, codec: MqttX.Payload.JSON)

    assert_receive {:broker_got, %{type: :publish} = pub}, 5_000
    assert pub.payload == ~s({"a":1})
    assert pub.properties == %{}
  end

  test "an encoding failure is returned to the caller and nothing is sent", ctx do
    client = connect(ctx, 5)

    # Raw only accepts binaries
    assert {:error, {:codec, {:not_binary, 42}}} =
             MqttX.Client.publish(client, "t", 42, codec: MqttX.Payload.Raw)

    refute_receive {:broker_got, _}, 300
  end

  test "without :codec a binary payload goes out untouched, as before", ctx do
    client = connect(ctx, 5)

    assert :ok = MqttX.Client.publish(client, "t", <<1, 2, 3>>)

    assert_receive {:broker_got, %{type: :publish} = pub}, 5_000
    assert pub.payload == <<1, 2, 3>>
    assert pub.properties == %{}
  end
end
