defmodule MqttX.Transport.CloseDrainTest do
  @moduledoc """
  A close the broker decides on delivers its DISCONNECT (#7): the TCP
  adapters half-close and keep reading what the client sends, so the client
  reads the packet and then sees an orderly close. A plain close with data
  still unread is a TCP reset, which can discard the DISCONNECT before the
  client reads it.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Handler do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp start(MqttX.Transport.Ranch) do
    refs_before = MapSet.new(Map.keys(:ranch.info()))

    {:ok, listener} =
      MqttX.Server.start_link(Handler, [], transport: MqttX.Transport.Ranch, port: 0)

    [ref] = Map.keys(:ranch.info()) |> Enum.reject(&MapSet.member?(refs_before, &1))
    {listener, :ranch.get_port(ref)}
  end

  defp start(MqttX.Transport.ThousandIsland) do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    {:ok, listener} = MqttX.Server.start_link(Handler, [], port: port)
    {listener, port}
  end

  defp connect_packet do
    {:ok, data} =
      Codec.encode(5, %{
        type: :connect,
        protocol_version: 5,
        client_id: "drain",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 60,
        properties: %{}
      })

    data
  end

  # Read until `count` packets have been decoded
  defp recv_packets(socket, count, buffer \\ <<>>, packets \\ [])

  defp recv_packets(_socket, count, _buffer, packets) when length(packets) >= count,
    do: {:ok, Enum.reverse(packets)}

  defp recv_packets(socket, count, buffer, packets) do
    case Codec.decode(5, buffer) do
      {:ok, {packet, rest}} ->
        recv_packets(socket, count, rest, [packet | packets])

      _incomplete ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> recv_packets(socket, count, buffer <> data, packets)
          {:error, reason} -> {:error, reason, Enum.reverse(packets)}
        end
    end
  end

  for transport <- [MqttX.Transport.ThousandIsland, MqttX.Transport.Ranch] do
    test "#{inspect(transport)}: a client still sending reads the DISCONNECT, then a clean close" do
      {listener, port} = start(unquote(transport))
      on_exit(fn -> if Process.alive?(listener), do: Process.exit(listener, :shutdown) end)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
      connect = connect_packet()

      # A second CONNECT is a protocol error (§3.1.0-2): DISCONNECT 0x82 and a
      # close, with far more behind it than the broker reads before closing
      :ok = :gen_tcp.send(socket, connect <> connect <> :binary.copy(<<0>>, 65_536))

      assert {:ok, [%{type: :connack}, %{type: :disconnect, reason_code: 0x82}]} =
               recv_packets(socket, 2)

      # The broker is still reading, so more data is not answered with a reset
      :ok = :gen_tcp.send(socket, :binary.copy(<<0>>, 65_536))
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    end
  end
end
