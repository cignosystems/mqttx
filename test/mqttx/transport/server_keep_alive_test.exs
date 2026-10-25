defmodule MqttX.Transport.ServerKeepAliveTest do
  @moduledoc """
  `:server_keep_alive` caps a v5 client's Keep Alive (§3.1.2.10,
  §3.2.2.3.14): one above the cap, or none, becomes the cap and CONNACK says
  so; one at or below it stands; a 3.1.1 client cannot be told.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Transport.Handler, as: Proto

  defmodule Handler do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  # CONNECT with `keep_alive` into a listener capped at `cap`: the CONNACK and
  # the connection's state
  defp connect(keep_alive, cap, version \\ 5) do
    table = MqttX.Server.RetainedStore.new_table()
    test = self()
    send_fn = fn data -> send(test, {:sent, data}) end
    opts = [transport_opts: %{server_keep_alive: cap}]
    {:ok, state} = Proto.init(Handler, opts, table, nil, send_fn)

    {:ok, data} =
      Codec.encode(version, %{
        type: :connect,
        protocol_version: version,
        client_id: "ka-#{keep_alive}",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: keep_alive,
        properties: %{}
      })

    {:ok, state} = Proto.handle_data(data, state)
    assert_receive {:sent, connack}

    {:ok, {%{type: :connack} = connack, <<>>}} =
      Codec.decode(version, IO.iodata_to_binary(connack))

    {connack, state}
  end

  test "a Keep Alive above the cap is lowered to it, and the client is told" do
    {connack, state} = connect(120, 60)
    assert connack.properties.server_keep_alive == 60
    assert state.keep_alive == 60
  end

  test "none (0) becomes the cap" do
    {connack, state} = connect(0, 60)
    assert connack.properties.server_keep_alive == 60
    assert state.keep_alive == 60
  end

  test "a Keep Alive at or below the cap stands, and CONNACK says nothing about it" do
    {connack, state} = connect(20, 60)
    refute Map.has_key?(connack.properties, :server_keep_alive)
    assert state.keep_alive == 20

    {connack, state} = connect(60, 60)
    refute Map.has_key?(connack.properties, :server_keep_alive)
    assert state.keep_alive == 60
  end

  test "without a cap the client's value stands" do
    {connack, state} = connect(120, nil)
    refute Map.has_key?(connack.properties, :server_keep_alive)
    assert state.keep_alive == 120
  end

  test "a 3.1.1 client is not capped: it could not be told" do
    {_connack, state} = connect(120, 60, 4)
    assert state.keep_alive == 120
  end
end
