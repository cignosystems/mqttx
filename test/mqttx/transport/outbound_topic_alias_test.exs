defmodule MqttX.Transport.OutboundTopicAliasTest do
  @moduledoc """
  Topic Aliases on the PUBLISHes the broker sends (§3.3.2.3.4, #10): to a v5
  client that set a Topic Alias Maximum, the first message on a topic carries
  topic and alias, later ones the alias alone, up to the maximum; to a client
  that set none, or with `outbound_topic_aliases: false`, no aliases.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec
  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  # A listener whose handle_publish/4 delivers; `transport_opts` go in the
  # handler options, as for any listener
  defp start(handler_opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    name = :"alias_#{port}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, server} =
          MqttX.Server.start_link(ClusterBroker, handler_opts, port: port, name: name)

        send(parent, {:started, server})
        Process.sleep(:infinity)
      end)

    server =
      receive do
        {:started, server} -> server
      after
        5_000 -> flunk("listener did not start")
      end

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {name, port}
  end

  # A raw v5 client subscribed to t/#, allowing `max` aliases (none when 0)
  defp raw_client(port, max) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    properties = if max > 0, do: %{topic_alias_maximum: max}, else: %{}

    {:ok, connect} =
      Codec.encode(5, %{
        type: :connect,
        protocol_version: 5,
        client_id: "alias-#{max}",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 60,
        properties: properties
      })

    :ok = :gen_tcp.send(socket, connect)
    assert [%{type: :connack, reason_code: 0}] = recv_packets(socket, 1)

    {:ok, subscribe} =
      Codec.encode(5, %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "t/#", qos: 0}],
        properties: %{}
      })

    :ok = :gen_tcp.send(socket, subscribe)
    assert [%{type: :suback}] = recv_packets(socket, 1)
    socket
  end

  defp recv_packets(socket, count, buffer \\ <<>>, acc \\ [])
  defp recv_packets(_socket, 0, _buffer, acc), do: Enum.reverse(acc)

  defp recv_packets(socket, count, buffer, acc) do
    case Codec.decode(5, buffer) do
      {:ok, {packet, rest}} ->
        recv_packets(socket, count - 1, rest, [packet | acc])

      _incomplete ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        recv_packets(socket, count, buffer <> data, acc)
    end
  end

  defp deliver(name, topic, payload),
    do: {:ok, 1} = MqttX.Server.deliver(name, topic, payload, %{qos: 0})

  test "the first PUBLISH on a topic carries topic and alias, later ones the alias alone" do
    {name, port} = start()
    socket = raw_client(port, 5)

    deliver(name, "t/a", "1")
    deliver(name, "t/a", "2")
    deliver(name, "t/b", "3")

    assert [
             %{topic: ["t", "a"], payload: "1", properties: %{topic_alias: 1}},
             %{topic: "", payload: "2", properties: %{topic_alias: 1}},
             %{topic: ["t", "b"], payload: "3", properties: %{topic_alias: 2}}
           ] = recv_packets(socket, 3)
  end

  test "past the client's maximum, a new topic goes without an alias; known ones keep theirs" do
    {name, port} = start()
    socket = raw_client(port, 1)

    deliver(name, "t/a", "1")
    deliver(name, "t/b", "2")
    deliver(name, "t/a", "3")

    assert [
             %{topic: ["t", "a"], properties: %{topic_alias: 1}},
             %{topic: ["t", "b"], properties: second},
             %{topic: "", payload: "3", properties: %{topic_alias: 1}}
           ] = recv_packets(socket, 3)

    refute Map.has_key?(second, :topic_alias)
  end

  test "a client that allows no aliases gets none" do
    {name, port} = start()
    socket = raw_client(port, 0)

    deliver(name, "t/a", "1")
    deliver(name, "t/a", "2")

    assert [%{topic: ["t", "a"], properties: p1}, %{topic: ["t", "a"], properties: p2}] =
             recv_packets(socket, 2)

    refute Map.has_key?(p1, :topic_alias)
    refute Map.has_key?(p2, :topic_alias)
  end

  test "outbound_topic_aliases: false turns them off" do
    {name, port} = start(transport_opts: %{outbound_topic_aliases: false})
    socket = raw_client(port, 5)

    deliver(name, "t/a", "1")
    deliver(name, "t/a", "2")

    assert [%{topic: ["t", "a"], properties: p1}, %{topic: ["t", "a"], properties: p2}] =
             recv_packets(socket, 2)

    refute Map.has_key?(p1, :topic_alias)
    refute Map.has_key?(p2, :topic_alias)
  end

  test "an MqttX client that allows aliases gets every message with its topic" do
    {name, port} = start()

    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: "alias-client",
        protocol_version: 5,
        await_connect: true,
        connect_properties: %{topic_alias_maximum: 3},
        handler: ForwardingHandler,
        handler_state: %{pid: self()}
      )

    {:ok, [0]} = MqttX.Client.subscribe(client, "t/#", qos: 0)
    deliver(name, "t/a", "1")
    deliver(name, "t/a", "2")

    assert_receive {:mqtt_event, :message, {["t", "a"], "1", first}}, 2_000
    assert_receive {:mqtt_event, :message, {["t", "a"], "2", second}}, 2_000
    assert first.properties.topic_alias == 1
    assert second.properties.topic_alias == 1

    MqttX.Client.disconnect(client)
  end
end
