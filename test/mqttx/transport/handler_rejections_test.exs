defmodule MqttX.Transport.HandlerRejectionsTest do
  @moduledoc """
  Ways the broker handler says no: the per-client message rate limit, CONNECT
  rejected for an unsupported protocol version (§3.2.2.2) or a zero-byte
  client id with CleanSession 0 (MQTT-3.1.3-8), and an AUTH packet on a
  connection whose CONNECT did not ask for enhanced authentication.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Packet.ReasonCodes, as: RC
  alias MqttX.Server.RateLimiter
  alias MqttX.Server.RetainedStore
  alias MqttX.Transport.Handler, as: Proto

  defmodule Recorder do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:handle_publish, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

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

  defp init(ctx, opts \\ []) do
    {:ok, state} =
      Proto.init(
        Recorder,
        Keyword.merge([notify: self()], Keyword.take(opts, [:transport_opts])),
        ctx.retained,
        Keyword.get(opts, :rate_limiter),
        ctx.send_fn
      )

    state
  end

  defp connect_packet(version, overrides \\ %{}) do
    Map.merge(
      %{
        type: :connect,
        protocol_version: version,
        client_id: "client-#{version}",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      },
      overrides
    )
  end

  defp encode(version, packet) do
    {:ok, data} = Codec.encode(version, packet)
    data
  end

  defp feed(state, version, packet) do
    {:ok, state} = Proto.handle_data(encode(version, packet), state)
    state
  end

  defp sent(version) do
    assert_received {:sent, data}
    {:ok, {packet, <<>>}} = Codec.decode(version, IO.iodata_to_binary(data))
    packet
  end

  defp publish(topic, payload, qos, packet_id) do
    %{
      type: :publish,
      topic: topic,
      payload: payload,
      qos: qos,
      retain: false,
      dup: false,
      packet_id: packet_id,
      properties: %{}
    }
  end

  describe "message rate limit" do
    test "excess publishes are refused with 0x97 Quota exceeded and never reach the handler",
         ctx do
      limiter = RateLimiter.new(max_messages: 1, interval: 60_000)
      state = init(ctx, rate_limiter: limiter)
      state = feed(state, 5, connect_packet(5))
      assert %{type: :connack, reason_code: 0} = sent(5)

      # One allowed per window
      state = feed(state, 5, publish("rl/t", "first", 1, 1))
      assert_received {:handle_publish, "rl/t", "first"}
      assert %{type: :puback, packet_id: 1, reason_code: 0} = sent(5)

      # QoS 1 over the limit: PUBACK 0x97 Quota exceeded — 0x96 Message rate
      # too high exists only for DISCONNECT (§2.4), and the session is kept
      state = feed(state, 5, publish("rl/t", "second", 1, 2))
      refute_received {:handle_publish, _, _}
      assert %{type: :puback, packet_id: 2, reason_code: 0x97} = sent(5)

      # QoS 2 over the limit: PUBREC 0x97, nothing held for PUBREL
      state = feed(state, 5, publish("rl/t", "third", 2, 3))
      refute_received {:handle_publish, _, _}
      assert %{type: :pubrec, packet_id: 3, reason_code: 0x97} = sent(5)
      assert state.pending_qos2_rx == %{}

      # QoS 0 over the limit: silently dropped
      _ = feed(state, 5, publish("rl/t", "fourth", 0, nil))
      refute_received {:handle_publish, _, _}
      refute_received {:sent, _}

      assert RC.quota_exceeded() == 0x97
    end
  end

  describe "CONNECT rejected" do
    test "a protocol version the listener does not accept gets 0x01 (v3.1.1) or 0x84 (v5)",
         ctx do
      state = init(ctx, transport_opts: %{supported_versions: [5]})

      assert {:close, :unsupported_protocol_version, _} =
               Proto.handle_data(encode(4, connect_packet(4)), state)

      assert %{type: :connack, reason_code: 0x01} = sent(4)

      state = init(ctx, transport_opts: %{supported_versions: [4]})

      assert {:close, :unsupported_protocol_version, _} =
               Proto.handle_data(encode(5, connect_packet(5)), state)

      assert %{type: :connack, reason_code: 0x84} = sent(5)
    end

    test "a v3.1.1 zero-byte client id with CleanSession 0 gets 0x02 Identifier rejected",
         ctx do
      state = init(ctx)
      packet = connect_packet(4, %{client_id: "", clean_session: false})

      assert {:close, :identifier_rejected, _} = Proto.handle_data(encode(4, packet), state)
      assert %{type: :connack, reason_code: 0x02} = sent(4)
    end
  end

  describe "AUTH without enhanced authentication" do
    test "on a connection whose CONNECT named no Authentication Method it is refused with 0x8C",
         ctx do
      state = init(ctx)
      state = feed(state, 5, connect_packet(5))
      assert %{type: :connack} = sent(5)

      auth = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "SCRAM"}}

      assert {:close, :auth_failed, closed} = Proto.handle_data(encode(5, auth), state)
      assert %{type: :disconnect, reason_code: 0x8C} = sent(5)
      # Server-initiated close: the Will would still publish (§3.1.2.5)
      refute closed.graceful_disconnect
      assert RC.bad_authentication_method() == 0x8C
    end
  end
end
