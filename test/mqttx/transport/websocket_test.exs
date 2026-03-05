defmodule MqttX.Transport.WebSocketTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MqttX.Packet.Codec

  defmodule TestHandler do
    use MqttX.Server

    @impl true
    def init(opts), do: %{agent: Keyword.fetch!(opts, :agent)}

    @impl true
    def handle_connect(client_id, _credentials, state) do
      Agent.update(state.agent, &[{:connect, client_id} | &1])
      {:ok, state}
    end

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic
      Agent.update(state.agent, &[{:publish, topic_str, payload} | &1])
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state) do
      Agent.update(state.agent, &[{:subscribe, topics} | &1])
      qos_list = Enum.map(topics, fn t -> Map.get(t, :qos, 0) end)
      {:ok, qos_list, state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      try do
        Agent.update(state.agent, &[{:disconnect, reason} | &1])
      catch
        :exit, _ -> :ok
      end

      :ok
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_ws_server(handler, handler_opts, opts \\ []) do
    port = Keyword.get(opts, :port, get_free_port())

    {:ok, server_pid} =
      MqttX.Server.start_link(handler, handler_opts,
        transport: MqttX.Transport.WebSocket,
        port: port
      )

    Process.sleep(100)
    {server_pid, port}
  end

  defp ws_connect(port) do
    # Open a TCP connection and perform WebSocket handshake manually
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    # WebSocket upgrade request
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET /mqtt HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Protocol: mqtt\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, request)

    # Read HTTP response
    {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
    assert response =~ "101 Switching Protocols"
    assert response =~ "sec-websocket-protocol: mqtt"

    socket
  end

  defp ws_send_binary(socket, data) do
    # Build a WebSocket binary frame
    import Bitwise
    payload = IO.iodata_to_binary(data)
    len = byte_size(payload)
    mask_key = :crypto.strong_rand_bytes(4)
    masked_payload = mask_payload(payload, mask_key)

    frame =
      if len < 126 do
        mask_bit = bor(0x80, len)
        <<0x82, mask_bit, mask_key::binary, masked_payload::binary>>
      else
        <<0x82, 0xFE, len::16, mask_key::binary, masked_payload::binary>>
      end

    :gen_tcp.send(socket, frame)
  end

  defp ws_recv_binary(socket, timeout \\ 5000) do
    {:ok, data} = :gen_tcp.recv(socket, 0, timeout)
    parse_ws_frame(data)
  end

  defp parse_ws_frame(<<_fin_rsv_opcode, 0::1, len::7, payload::binary-size(len), _rest::binary>>)
       when len < 126 do
    payload
  end

  defp parse_ws_frame(<<_fin_rsv_opcode, 0::1, 126::7, len::16, rest::binary>>) do
    <<payload::binary-size(len), _::binary>> = rest
    payload
  end

  defp mask_payload(payload, mask_key) do
    mask_bytes = :binary.copy(mask_key, div(byte_size(payload), 4) + 1)
    :crypto.exor(payload, binary_part(mask_bytes, 0, byte_size(payload)))
  end

  describe "WebSocket MQTT connection" do
    test "client connects via WebSocket and exchanges MQTT packets" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      socket = ws_connect(port)

      # Send MQTT CONNECT
      connect_packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "ws-test-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, connect_data} = Codec.encode(4, connect_packet)
      :ok = ws_send_binary(socket, connect_data)

      # Receive CONNACK
      connack_data = ws_recv_binary(socket)
      {:ok, {connack, <<>>}} = Codec.decode(4, connack_data)
      assert connack.type == :connack
      assert connack.reason_code == 0

      # Verify handler received connect
      Process.sleep(50)
      events = Agent.get(agent, & &1)
      assert {:connect, "ws-test-client"} in events

      :gen_tcp.close(socket)
    end

    test "client can publish over WebSocket" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      socket = ws_connect(port)

      # CONNECT
      connect_packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "ws-pub-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, connect_data} = Codec.encode(4, connect_packet)
      :ok = ws_send_binary(socket, connect_data)
      _connack = ws_recv_binary(socket)

      # PUBLISH
      publish_packet = %{
        type: :publish,
        topic: "ws/test",
        payload: "hello websocket",
        qos: 0,
        retain: false,
        dup: false,
        packet_id: nil,
        properties: %{}
      }

      {:ok, publish_data} = Codec.encode(4, publish_packet)
      :ok = ws_send_binary(socket, publish_data)

      Process.sleep(100)
      events = Agent.get(agent, & &1)
      assert {:publish, "ws/test", "hello websocket"} in events

      :gen_tcp.close(socket)
    end

    test "client can subscribe over WebSocket" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      socket = ws_connect(port)

      # CONNECT
      connect_packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "ws-sub-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, connect_data} = Codec.encode(4, connect_packet)
      :ok = ws_send_binary(socket, connect_data)
      _connack = ws_recv_binary(socket)

      # SUBSCRIBE
      subscribe_packet = %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "ws/#", qos: 0}],
        properties: %{}
      }

      {:ok, subscribe_data} = Codec.encode(4, subscribe_packet)
      :ok = ws_send_binary(socket, subscribe_data)

      # Receive SUBACK
      suback_data = ws_recv_binary(socket)
      {:ok, {suback, <<>>}} = Codec.decode(4, suback_data)
      assert suback.type == :suback
      assert suback.packet_id == 1

      :gen_tcp.close(socket)
    end

    test "client can send PINGREQ over WebSocket" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      socket = ws_connect(port)

      # CONNECT
      connect_packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "ws-ping-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, connect_data} = Codec.encode(4, connect_packet)
      :ok = ws_send_binary(socket, connect_data)
      _connack = ws_recv_binary(socket)

      # PINGREQ
      {:ok, ping_data} = Codec.encode(4, %{type: :pingreq})
      :ok = ws_send_binary(socket, ping_data)

      # PINGRESP
      pingresp_data = ws_recv_binary(socket)
      {:ok, {pingresp, <<>>}} = Codec.decode(4, pingresp_data)
      assert pingresp.type == :pingresp

      :gen_tcp.close(socket)
    end

    test "rejects connection without mqtt subprotocol" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      key = Base.encode64(:crypto.strong_rand_bytes(16))

      request =
        "GET /mqtt HTTP/1.1\r\n" <>
          "Host: 127.0.0.1:#{port}\r\n" <>
          "Upgrade: websocket\r\n" <>
          "Connection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: #{key}\r\n" <>
          "Sec-WebSocket-Version: 13\r\n" <>
          "\r\n"

      :ok = :gen_tcp.send(socket, request)
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      assert response =~ "400"

      :gen_tcp.close(socket)
    end

    test "graceful DISCONNECT over WebSocket" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {_server_pid, port} = start_ws_server(TestHandler, agent: agent)

      socket = ws_connect(port)

      # CONNECT
      connect_packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "ws-disc-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, connect_data} = Codec.encode(4, connect_packet)
      :ok = ws_send_binary(socket, connect_data)
      _connack = ws_recv_binary(socket)

      # DISCONNECT
      disconnect_packet = %{type: :disconnect, reason_code: 0, properties: %{}}
      {:ok, disconnect_data} = Codec.encode(4, disconnect_packet)
      :ok = ws_send_binary(socket, disconnect_data)

      # Give the server time to process
      Process.sleep(100)
      events = Agent.get(agent, & &1)
      assert {:disconnect, :normal} in events

      :gen_tcp.close(socket)
    end
  end
end
