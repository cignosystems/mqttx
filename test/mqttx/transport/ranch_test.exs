defmodule MqttX.Transport.RanchTest do
  # Regression tests for the Ranch adapter: the protocol used to run
  # `:ranch.handshake/1` inside GenServer.init/1, deadlocking ranch's
  # connection supervisor on the first inbound connection.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule EchoHandler do
    use MqttX.Server

    @impl true
    def init(_opts), do: %{}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  setup do
    port = get_free_port()

    {:ok, listener} =
      MqttX.Server.start_link(EchoHandler, [],
        transport: MqttX.Transport.Ranch,
        port: port
      )

    on_exit(fn ->
      if Process.alive?(listener), do: Process.exit(listener, :shutdown)
    end)

    {:ok, port: port}
  end

  test "accepts a connection and completes CONNECT/CONNACK", %{port: port} do
    assert {:ok, socket} =
             :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2_000)

    :ok = :gen_tcp.send(socket, encode_connect("ranch-client-1"))
    assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:ok, {%{type: :connack, reason_code: 0}, <<>>}} = Codec.decode(4, data)
    :gen_tcp.close(socket)
  end

  test "accepts further connections after the first (conns_sup not wedged)", %{port: port} do
    sockets =
      for i <- 1..3 do
        assert {:ok, socket} =
                 :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2_000)

        :ok = :gen_tcp.send(socket, encode_connect("ranch-client-#{i}"))
        assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        assert {:ok, {%{type: :connack, reason_code: 0}, <<>>}} = Codec.decode(4, data)
        socket
      end

    Enum.each(sockets, &:gen_tcp.close/1)
  end

  test "PINGREQ round-trips", %{port: port} do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2_000)
    :ok = :gen_tcp.send(socket, encode_connect("ranch-ping"))
    {:ok, _connack} = :gen_tcp.recv(socket, 0, 2_000)

    {:ok, pingreq} = Codec.encode(4, %{type: :pingreq})
    :ok = :gen_tcp.send(socket, pingreq)
    assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:ok, {%{type: :pingresp}, <<>>}} = Codec.decode(4, data)
    :gen_tcp.close(socket)
  end

  defp encode_connect(client_id) do
    {:ok, data} =
      Codec.encode(4, %{
        type: :connect,
        protocol_version: 4,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 60,
        properties: %{}
      })

    data
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
