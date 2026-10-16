defmodule MqttX.Client.WSDataFrameTest do
  @moduledoc """
  MQTT-6.0.0-1 at the connection level: MQTT Control Packets travel in
  WebSocket *binary* data frames, and a client receiving any other kind of
  data frame MUST close the Network Connection. A minimal scripted WebSocket
  server performs the upgrade, answers the CONNECT, then sends whatever frame
  the test asks for.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Client.WebSocket
  alias MqttX.Packet.Codec
  alias MqttX.Test.ForwardingHandler

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # --- scripted WebSocket server -------------------------------------------

  defp start_server do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, test_pid) end)
    %{pid: pid, port: port}
  end

  defp accept_loop(listen, test_pid) do
    {:ok, sock} = :gen_tcp.accept(listen)
    request = recv_until(sock, <<>>, "\r\n\r\n")
    [_, key] = Regex.run(~r/Sec-WebSocket-Key:\s*([^\r\n]+)/i, request)
    accept = Base.encode64(:crypto.hash(:sha, String.trim(key) <> @ws_guid))

    :ok =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 101 Switching Protocols\r\n" <>
          "Upgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n"
      )

    # The client's (masked) CONNECT frame
    [connect_bytes] = recv_payloads(sock, <<>>)
    {:ok, {%{type: :connect} = connect, <<>>}} = Codec.decode(5, connect_bytes)
    send(test_pid, {:ws_server, :connect, connect})

    {:ok, connack} =
      Codec.encode(5, %{type: :connack, session_present: false, reason_code: 0, properties: %{}})

    :ok = :gen_tcp.send(sock, binary_frame(connack))
    :ok = :inet.setopts(sock, active: :once)
    relay(sock, test_pid)
    send(test_pid, {:ws_server, :closed})
    accept_loop(listen, test_pid)
  end

  defp recv_until(sock, buffer, marker) do
    if String.contains?(buffer, marker) do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      recv_until(sock, buffer <> data, marker)
    end
  end

  defp recv_payloads(sock, buffer) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)

    case WebSocket.decode_frames(buffer <> data) do
      {:ok, [], [], rest, _frag} -> recv_payloads(sock, rest)
      {:ok, payloads, _pings, _rest, _frag} -> payloads
    end
  end

  defp relay(sock, test_pid) do
    receive do
      {:tcp, ^sock, data} ->
        send(test_pid, {:ws_server, :data, data})
        :ok = :inet.setopts(sock, active: :once)
        relay(sock, test_pid)

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _} ->
        :ok

      {:send_raw, data} ->
        :ok = :gen_tcp.send(sock, data)
        relay(sock, test_pid)
    end
  end

  # Unmasked server-to-client frame; payloads here are always short
  defp frame(payload, opcode) when byte_size(payload) < 126 do
    <<1::1, 0::3, opcode::4, 0::1, byte_size(payload)::7>> <> payload
  end

  defp binary_frame(payload), do: frame(payload, 0x2)

  # --- client ---------------------------------------------------------------

  defp start_client(port) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: port,
        transport: :ws,
        client_id: "ws-frame-#{System.unique_integer([:positive])}",
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

  @pingresp <<0xD0, 0>>

  test "MQTT in a binary frame is processed" do
    server = start_server()
    client = start_client(server.port)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    {:ok, publish} =
      Codec.encode(5, %{
        type: :publish,
        topic: "ws/ok",
        payload: "bin",
        qos: 0,
        retain: false,
        dup: false,
        packet_id: nil,
        properties: %{}
      })

    send(server.pid, {:send_raw, binary_frame(publish)})
    assert_receive {:mqtt_event, :message, {["ws", "ok"], "bin", _}}, 2_000
    assert Connection.connected?(client)
  end

  test "a text frame closes the connection as a protocol error (MQTT-6.0.0-1)" do
    server = start_server()
    client = start_client(server.port)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    # Perfectly valid MQTT bytes (a PINGRESP) in the wrong kind of frame
    send(server.pid, {:send_raw, frame(@pingresp, 0x1)})

    assert_receive {:mqtt_event, :disconnected, {:protocol_error, :non_binary_frame}}, 2_000
    assert_receive {:ws_server, :closed}, 2_000
    refute Connection.connected?(client)
  end

  test "a reserved data opcode closes the connection too" do
    server = start_server()
    client = start_client(server.port)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    send(server.pid, {:send_raw, frame(@pingresp, 0x3)})

    assert_receive {:mqtt_event, :disconnected, {:protocol_error, :non_binary_frame}}, 2_000
    assert_receive {:ws_server, :closed}, 2_000
    refute Connection.connected?(client)
  end
end
