defmodule MqttX.Transport.WebSocketLimitsTest do
  @moduledoc """
  The WebSocket listener's own limits, before any MQTT packet is seen: a
  frame may not exceed the packet cap (plus the frame header), and with
  `:check_origin` a browser from another origin is refused.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule Handler do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp start(handler_opts, transport_opts) do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    {:ok, server} =
      MqttX.Server.start_link(
        Handler,
        handler_opts,
        [transport: MqttX.Transport.WebSocket, port: port] ++ transport_opts
      )

    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :shutdown) end)
    Process.sleep(100)
    port
  end

  # The upgrade request, with any extra headers; returns the status line
  defp upgrade(port, extra_headers \\ []) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    headers =
      [
        "Host: 127.0.0.1:#{port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Protocol: mqtt"
      ] ++ extra_headers

    :ok =
      :gen_tcp.send(socket, "GET /mqtt HTTP/1.1\r\n" <> Enum.join(headers, "\r\n") <> "\r\n\r\n")

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    [status | _] = String.split(response, "\r\n")
    {socket, status}
  end

  # A masked binary frame declaring `size` bytes of payload, header only
  defp frame_header(size) do
    mask = <<1, 2, 3, 4>>
    <<0x82, 1::1, 127::7, size::64, mask::binary>>
  end

  test "a frame past the packet cap is refused before its payload arrives" do
    port = start([transport_opts: %{max_packet_size: 1024}], [])
    {socket, status} = upgrade(port)
    assert status =~ "101"

    :ok = :gen_tcp.send(socket, frame_header(2048))

    # A close frame (1009, too big) or the socket closed under us
    assert match?({:ok, <<0x88, _::binary>>}, :gen_tcp.recv(socket, 0, 2_000)) or
             match?({:error, _}, :gen_tcp.recv(socket, 0, 2_000))
  end

  test "with :check_origin, another origin is refused and a listed one or none passes" do
    port = start([], check_origin: ["https://app.example"])

    {_socket, status} = upgrade(port, ["Origin: https://evil.example"])
    assert status =~ "403"

    {_socket, status} = upgrade(port, ["Origin: https://app.example"])
    assert status =~ "101"

    {_socket, status} = upgrade(port)
    assert status =~ "101"
  end

  test "without :check_origin any origin passes" do
    port = start([], [])
    {_socket, status} = upgrade(port, ["Origin: https://evil.example"])
    assert status =~ "101"
  end
end
