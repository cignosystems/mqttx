defmodule MqttX.Transport.HandlerEnhancedAuthTest do
  @moduledoc """
  Edges of MQTT 5.0 enhanced authentication (§4.12) in the broker handler,
  beyond the happy path in `handler_test.exs`: the mechanism's final data in
  the CONNACK, the ways a client can break the exchange (wrong method, wrong
  reason code, any other packet), what happens if it stalls or the socket drops
  before CONNACK, and a handler that implements the behaviour without
  `handle_auth/3`.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Server.RetainedStore
  alias MqttX.Transport.Handler, as: Proto

  @method "TOY"

  defmodule Mechanism do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    # Takes precedence over the 3-arity form, and sees connect_info
    @impl true
    def handle_connect(_client_id, _credentials, connect_info, state) do
      send(state.notify, {:handle_connect, connect_info})
      {:ok, state}
    end

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:handle_publish, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(reason, state) do
      send(state.notify, {:handle_disconnect, reason})
      :ok
    end

    # Challenge with a nonce; accept "proof:" <> nonce and finish with a
    # server-final message
    @impl true
    def handle_auth("TOY", nil, state), do: {:continue, "nonce", state}
    def handle_auth("TOY", "proof:nonce", state), do: {:ok, "server-final", state}
    def handle_auth("TOY", _wrong, state), do: {:error, 0x87, state}
  end

  # Implements the behaviour by hand: no `use MqttX.Server`, no handle_auth/3
  defmodule Bare do
    @moduledoc false
    @behaviour MqttX.Server

    @impl true
    def init(_opts), do: %{}
    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  setup do
    retained = RetainedStore.new_table()
    send_fn = fn data -> send(self(), {:sent, data}) end
    {:ok, retained: retained, send_fn: send_fn}
  end

  defp init(ctx, handler \\ Mechanism) do
    {:ok, state} = Proto.init(handler, [notify: self()], ctx.retained, nil, ctx.send_fn)
    state
  end

  defp connect(client_id, properties, extra \\ %{}) do
    Map.merge(
      %{
        type: :connect,
        protocol_version: 5,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: properties
      },
      extra
    )
  end

  defp auth(reason_code, method, data) do
    props = %{authentication_method: method}
    props = if data, do: Map.put(props, :authentication_data, data), else: props
    %{type: :auth, reason_code: reason_code, properties: props}
  end

  defp encode(packet) do
    {:ok, data} = Codec.encode(5, packet)
    data
  end

  defp feed(state, packet) do
    {:ok, state} = Proto.handle_data(encode(packet), state)
    state
  end

  defp sent do
    assert_received {:sent, data}
    {:ok, {packet, <<>>}} = Codec.decode(5, IO.iodata_to_binary(data))
    packet
  end

  # CONNECT with the method, challenge received — mid-exchange
  defp mid_exchange(ctx, client_id, extra \\ %{}) do
    state = feed(init(ctx), connect(client_id, %{authentication_method: @method}, extra))
    assert %{type: :auth, reason_code: 0x18, properties: %{authentication_data: "nonce"}} = sent()
    refute state.connected
    state
  end

  test "{:ok, data, state} puts the mechanism's final data in the CONNACK, and handle_connect/4 saw the method",
       ctx do
    state = mid_exchange(ctx, "final-data")
    assert_received {:handle_connect, %{protocol_version: 5, authentication_method: @method}}

    state = feed(state, auth(0x18, @method, "proof:nonce"))

    assert %{type: :connack, reason_code: 0, properties: props} = sent()
    assert props.authentication_method == @method
    assert props.authentication_data == "server-final"
    assert state.connected

    # The session really is up: a publish reaches the handler
    _ =
      feed(state, %{
        type: :publish,
        topic: "after/auth",
        payload: "ok",
        qos: 0,
        retain: false,
        dup: false,
        packet_id: nil,
        properties: %{}
      })

    assert_received {:handle_publish, "after/auth", "ok"}
  end

  test "an answer naming a different method fails the CONNECT with 0x8C", ctx do
    state = mid_exchange(ctx, "wrong-method")

    assert {:close, :auth_failed, _} =
             Proto.handle_data(encode(auth(0x18, "OTHER", "proof:nonce")), state)

    assert %{type: :connack, reason_code: 0x8C} = sent()
  end

  test "an answer that is not 0x18 Continue authentication is a Protocol Error", ctx do
    state = mid_exchange(ctx, "wrong-code")

    # 0x19 Re-authenticate belongs to a live connection (§4.12.1), not here
    assert {:close, :auth_failed, _} =
             Proto.handle_data(encode(auth(0x19, @method, "proof:nonce")), state)

    assert %{type: :connack, reason_code: 0x82} = sent()
  end

  test "any other packet during the exchange fails the CONNECT with CONNACK 0x82, never a DISCONNECT",
       ctx do
    publish = %{
      type: :publish,
      topic: "too/early",
      payload: "x",
      qos: 0,
      retain: false,
      dup: false,
      packet_id: nil,
      properties: %{}
    }

    state = mid_exchange(ctx, "early-publish")
    assert {:close, :auth_failed, _} = Proto.handle_data(encode(publish), state)
    assert %{type: :connack, reason_code: 0x82} = sent()
    refute_received {:handle_publish, _, _}

    # A second CONNECT is no better
    state = mid_exchange(ctx, "second-connect")

    assert {:close, :auth_failed, _} =
             Proto.handle_data(encode(connect("second-connect", %{})), state)

    assert %{type: :connack, reason_code: 0x82} = sent()
  end

  test "a stalled exchange is still ended by the CONNECT deadline", ctx do
    state = mid_exchange(ctx, "stalled")
    assert {:stop, :normal, _} = Proto.handle_info(:mqtt_connect_timeout, state)
  end

  test "a socket dropped before CONNACK fires neither the Will nor handle_disconnect", ctx do
    will = %{topic: "will/t", payload: "gone", qos: 0, retain: true, properties: %{}}
    state = mid_exchange(ctx, "dropped", %{will: will})

    assert {:shutdown, _} = Proto.handle_close(state)

    refute_received {:handle_disconnect, _}
    # The Will would have been offered to handle_publish and then retained
    refute_received {:handle_publish, "will/t", _}
    assert RetainedStore.match(ctx.retained, "will/t") == []
  end

  test "AUTH as the very first packet closes the connection without a reply", ctx do
    # Before CONNECT there is no protocol version: the bytes are read as
    # v3.1.1, where packet type 15 does not exist, so the decoder closes the
    # connection first. Either way nothing goes out (MQTT-3.14.0-1).
    assert {outcome, _reason, _state} =
             Proto.handle_data(encode(auth(0x18, @method, nil)), init(ctx))

    assert outcome in [:close, :error]
    refute_received {:sent, _}
  end

  test "a handler implementing the behaviour without handle_auth/3 refuses with 0x8C", ctx do
    state = init(ctx, Bare)

    assert {:close, :auth_failed, _} =
             Proto.handle_data(encode(connect("bare", %{authentication_method: @method})), state)

    assert %{type: :connack, reason_code: 0x8C} = sent()
  end
end
