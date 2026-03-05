defmodule MqttX.Transport.HandlerTest do
  use ExUnit.Case, async: true

  alias MqttX.Transport.Handler, as: Proto
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

  defmodule RejectHandler do
    use MqttX.Server

    @impl true
    def init(_opts), do: %{}

    @impl true
    def handle_connect(_client_id, _credentials, state) do
      {:error, 0x86, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn _ -> 0 end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  defmodule DisconnectOnPublishHandler do
    @moduledoc "Handler that returns {:disconnect, ...} from handle_publish and supports handle_info"
    use MqttX.Server

    @impl true
    def init(opts), do: %{agent: Keyword.fetch!(opts, :agent)}

    @impl true
    def handle_connect(client_id, _credentials, state) do
      Agent.update(state.agent, &[{:connect, client_id} | &1])
      {:ok, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state) do
      {:disconnect, 0x8E, state}
    end

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
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

    @impl true
    def handle_info(msg, state) do
      case msg do
        {:trigger_disconnect, code} ->
          {:disconnect, code, state}

        _ ->
          {:ok, state}
      end
    end
  end

  defmodule TestAuthHandler do
    @moduledoc "Handler with custom handle_auth for challenge-response testing"
    use MqttX.Server

    @impl true
    def init(opts), do: %{agent: Keyword.fetch!(opts, :agent)}

    @impl true
    def handle_connect(client_id, _credentials, state) do
      Agent.update(state.agent, &[{:connect, client_id} | &1])
      {:ok, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok

    @impl true
    def handle_auth("PLAIN", nil, state) do
      {:continue, "challenge-data", state}
    end

    def handle_auth("PLAIN", "correct-response", state) do
      {:ok, state}
    end

    def handle_auth("PLAIN", _wrong, state) do
      {:error, 0x87, state}
    end
  end

  defmodule PublishOnInfoHandler do
    @moduledoc "Handler that publishes via handle_info"
    use MqttX.Server

    @impl true
    def init(opts), do: %{agent: Keyword.fetch!(opts, :agent)}

    @impl true
    def handle_connect(client_id, _credentials, state) do
      Agent.update(state.agent, &[{:connect, client_id} | &1])
      {:ok, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok

    @impl true
    def handle_info({:send_publish, topic, payload}, state) do
      {:publish, topic, payload, %{qos: 0, retain: false}, state}
    end

    def handle_info({:send_publish, topic, payload, opts}, state) do
      {:publish, topic, payload, opts, state}
    end

    def handle_info(_msg, state) do
      {:ok, state}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    retained_table = :ets.new(:handler_test_retained, [:public, :set])
    send_fn = fn data -> send(self(), {:sent, data}) end

    {:ok, agent: agent, retained_table: retained_table, send_fn: send_fn}
  end

  describe "init/5" do
    test "initializes protocol state", ctx do
      {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      assert state.connected == false
      assert state.buffer == <<>>
      assert state.handler == TestHandler
    end

    test "returns error when rate limited", ctx do
      rate_limiter = MqttX.Server.RateLimiter.new(max_connections: 0)
      result = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, rate_limiter, ctx.send_fn)

      assert result == {:error, :rate_limited}
    end
  end

  describe "handle_data/2 — CONNECT flow" do
    test "processes CONNECT and sends CONNACK", ctx do
      {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect,
        protocol_version: 4,
        client_id: "test-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, data} = Codec.encode(4, connect)
      {:ok, new_state} = Proto.handle_data(data, state)

      assert new_state.connected == true
      assert new_state.client_id == "test-client"
      assert new_state.protocol_version == 4

      # Verify CONNACK was sent
      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(4, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.reason_code == 0
    end

    test "processes CONNECT rejection", ctx do
      {:ok, state} = Proto.init(RejectHandler, [], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect,
        protocol_version: 4,
        client_id: "rejected-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, data} = Codec.encode(4, connect)
      {:close, :auth_failed, _state} = Proto.handle_data(data, state)

      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(4, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.reason_code == 0x86
    end
  end

  describe "handle_data/2 — PUBLISH flow" do
    test "processes PUBLISH after CONNECT", ctx do
      state = connect_client(ctx, "pub-client")

      publish = %{
        type: :publish,
        topic: "test/topic",
        payload: "hello",
        qos: 0,
        retain: false,
        dup: false,
        packet_id: nil,
        properties: %{}
      }

      {:ok, data} = Codec.encode(4, publish)
      {:ok, _new_state} = Proto.handle_data(data, state)

      events = Agent.get(ctx.agent, & &1)
      assert {:publish, "test/topic", "hello"} in events
    end

    test "sends PUBACK for QoS 1 PUBLISH", ctx do
      state = connect_client(ctx, "qos1-client")

      # Drain the CONNACK message from the mailbox
      receive do
        {:sent, _} -> :ok
      end

      publish = %{
        type: :publish,
        topic: "test/topic",
        payload: "hello",
        qos: 1,
        retain: false,
        dup: false,
        packet_id: 42,
        properties: %{}
      }

      {:ok, data} = Codec.encode(4, publish)
      {:ok, _new_state} = Proto.handle_data(data, state)

      assert_received {:sent, puback_data}
      {:ok, {puback, <<>>}} = Codec.decode(4, IO.iodata_to_binary(puback_data))
      assert puback.type == :puback
      assert puback.packet_id == 42
    end
  end

  describe "handle_data/2 — SUBSCRIBE flow" do
    test "processes SUBSCRIBE and sends SUBACK", ctx do
      state = connect_client(ctx, "sub-client")

      # Drain CONNACK
      receive do
        {:sent, _} -> :ok
      end

      subscribe = %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "test/#", qos: 0}],
        properties: %{}
      }

      {:ok, data} = Codec.encode(4, subscribe)
      {:ok, _new_state} = Proto.handle_data(data, state)

      assert_received {:sent, suback_data}
      {:ok, {suback, <<>>}} = Codec.decode(4, IO.iodata_to_binary(suback_data))
      assert suback.type == :suback
      assert suback.packet_id == 1
    end
  end

  describe "handle_data/2 — PINGREQ" do
    test "responds with PINGRESP", ctx do
      state = connect_client(ctx, "ping-client")

      # Drain CONNACK
      receive do
        {:sent, _} -> :ok
      end

      pingreq = %{type: :pingreq}
      {:ok, data} = Codec.encode(4, pingreq)
      {:ok, _new_state} = Proto.handle_data(data, state)

      assert_received {:sent, pingresp_data}
      {:ok, {pingresp, <<>>}} = Codec.decode(4, IO.iodata_to_binary(pingresp_data))
      assert pingresp.type == :pingresp
    end
  end

  describe "handle_data/2 — DISCONNECT" do
    test "processes graceful disconnect", ctx do
      state = connect_client(ctx, "disc-client")

      disconnect = %{type: :disconnect, reason_code: 0, properties: %{}}
      {:ok, data} = Codec.encode(4, disconnect)
      {:close, :disconnect, new_state} = Proto.handle_data(data, state)

      assert new_state.graceful_disconnect == true

      events = Agent.get(ctx.agent, & &1)
      assert {:disconnect, :normal} in events
    end
  end

  describe "handle_close/1" do
    test "emits disconnect event for ungraceful close", ctx do
      state = connect_client(ctx, "close-client")

      {:shutdown, _} = Proto.handle_close(state)

      events = Agent.get(ctx.agent, & &1)
      assert {:disconnect, :closed} in events
    end
  end

  describe "handle_timeout/1" do
    test "triggers disconnect on timeout", ctx do
      state = connect_client(ctx, "timeout-client")

      {:close, _} = Proto.handle_timeout(state)

      events = Agent.get(ctx.agent, & &1)
      assert {:disconnect, :timeout} in events
    end
  end

  describe "handle_info/2" do
    test "handles keepalive timeout", ctx do
      state = connect_client(ctx, "ka-client")

      {:stop, :normal, _} = Proto.handle_info(:keepalive_timeout, state)

      events = Agent.get(ctx.agent, & &1)
      assert {:disconnect, :keepalive_timeout} in events
    end

    test "handles server disconnect", ctx do
      state = connect_client(ctx, "sd-client")

      {:stop, :normal, new_state} = Proto.handle_info({:server_disconnect, 0x8E, %{}}, state)
      assert new_state.graceful_disconnect == true
    end

    test "ignores unknown messages when handler has no handle_info", ctx do
      state = connect_client(ctx, "ignore-client")

      {:noreply, ^state} = Proto.handle_info(:unknown_message, state)
    end
  end

  describe "handle_data/2 — incomplete data" do
    test "buffers incomplete packets", ctx do
      {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect,
        protocol_version: 4,
        client_id: "buffer-client",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      }

      {:ok, full_data} = Codec.encode(4, connect)
      # Send only the first half
      half = div(byte_size(full_data), 2)
      <<first_half::binary-size(half), second_half::binary>> = full_data

      {:ok, state} = Proto.handle_data(first_half, state)
      assert state.connected == false

      # Send second half
      {:ok, state} = Proto.handle_data(second_half, state)
      assert state.connected == true
    end
  end

  # ===== Feature 1: QoS 2 Full Flow & DUP Handling =====

  describe "QoS 2 full flow" do
    test "PUBLISH → PUBREC → PUBREL → PUBCOMP", ctx do
      state = connect_client(ctx, "qos2-client")
      drain_mailbox()

      # Send QoS 2 PUBLISH
      publish = %{
        type: :publish, topic: "qos2/topic", payload: "qos2-msg",
        qos: 2, retain: false, dup: false, packet_id: 10, properties: %{}
      }
      {:ok, data} = Codec.encode(4, publish)
      {:ok, state} = Proto.handle_data(data, state)

      # Should get PUBREC
      assert_received {:sent, pubrec_data}
      {:ok, {pubrec, <<>>}} = Codec.decode(4, IO.iodata_to_binary(pubrec_data))
      assert pubrec.type == :pubrec
      assert pubrec.packet_id == 10

      # Message should NOT be delivered yet
      events = Agent.get(ctx.agent, & &1)
      refute Enum.any?(events, fn e -> match?({:publish, _, _}, e) end)

      # Send PUBREL
      pubrel = %{type: :pubrel, packet_id: 10}
      {:ok, data} = Codec.encode(4, pubrel)
      {:ok, _state} = Proto.handle_data(data, state)

      # Should get PUBCOMP
      assert_received {:sent, pubcomp_data}
      {:ok, {pubcomp, <<>>}} = Codec.decode(4, IO.iodata_to_binary(pubcomp_data))
      assert pubcomp.type == :pubcomp
      assert pubcomp.packet_id == 10

      # NOW the message should be delivered
      events = Agent.get(ctx.agent, & &1)
      assert {:publish, "qos2/topic", "qos2-msg"} in events
    end

    test "DUP PUBLISH resends PUBREC without re-storing", ctx do
      state = connect_client(ctx, "qos2-dup")
      drain_mailbox()

      publish = %{
        type: :publish, topic: "dup/topic", payload: "dup-msg",
        qos: 2, retain: false, dup: false, packet_id: 20, properties: %{}
      }
      {:ok, data} = Codec.encode(4, publish)
      {:ok, state} = Proto.handle_data(data, state)

      assert_received {:sent, _pubrec1}

      # Send DUP PUBLISH with same packet_id
      dup_publish = %{publish | dup: true}
      {:ok, data} = Codec.encode(4, dup_publish)
      {:ok, state2} = Proto.handle_data(data, state)

      # Should get another PUBREC
      assert_received {:sent, pubrec2_data}
      {:ok, {pubrec2, <<>>}} = Codec.decode(4, IO.iodata_to_binary(pubrec2_data))
      assert pubrec2.type == :pubrec
      assert pubrec2.packet_id == 20

      # Inflight count should not have increased
      assert state2.inflight_count == state.inflight_count
    end

    test "retry timer fires and resends PUBREC for stale RX entries", ctx do
      state = connect_client(ctx, "qos2-retry")
      drain_mailbox()

      # Manually create a stale pending entry (timestamp in the past)
      past = System.monotonic_time(:millisecond) - 10_000
      packet = %{type: :publish, topic: "retry/topic", payload: "retry-msg",
                 qos: 2, retain: false, dup: false, packet_id: 30, properties: %{}}
      opts = %{qos: 2, retain: false, dup: false, packet_id: 30, properties: %{}}
      state = %{state | pending_qos2_rx: %{30 => {packet, opts, past, 0}}}

      {:noreply, new_state} = Proto.handle_info(:check_qos2_retry, state)

      # Should have resent PUBREC
      assert_received {:sent, pubrec_data}
      {:ok, {pubrec, <<>>}} = Codec.decode(4, IO.iodata_to_binary(pubrec_data))
      assert pubrec.type == :pubrec
      assert pubrec.packet_id == 30

      # Retry count should have incremented
      {_p, _o, _ts, retries} = new_state.pending_qos2_rx[30]
      assert retries == 1
    end

    test "drops entries after max retries", ctx do
      state = connect_client(ctx, "qos2-drop")
      drain_mailbox()

      past = System.monotonic_time(:millisecond) - 10_000
      packet = %{type: :publish, topic: "drop/topic", payload: "drop",
                 qos: 2, retain: false, dup: false, packet_id: 40, properties: %{}}
      opts = %{qos: 2, retain: false, dup: false, packet_id: 40, properties: %{}}
      state = %{state | pending_qos2_rx: %{40 => {packet, opts, past, 3}}, inflight_count: 1}

      {:noreply, new_state} = Proto.handle_info(:check_qos2_retry, state)

      # Entry should be dropped
      assert new_state.pending_qos2_rx == %{}
      assert new_state.inflight_count == 0
    end
  end

  describe "PUBREL with unknown packet_id" do
    test "sends PUBCOMP with reason_code 0x92 (MQTT 5.0)", ctx do
      state = connect_client_v5(ctx, "pubrel-unknown")
      drain_mailbox()

      # Send PUBREL with a packet_id that was never part of a QoS 2 flow
      pubrel = %{type: :pubrel, packet_id: 999}
      {:ok, data} = Codec.encode(5, pubrel)
      {:ok, _state} = Proto.handle_data(data, state)

      assert_received {:sent, pubcomp_data}
      {:ok, {pubcomp, <<>>}} = Codec.decode(5, IO.iodata_to_binary(pubcomp_data))
      assert pubcomp.type == :pubcomp
      assert pubcomp.packet_id == 999
      assert pubcomp.reason_code == 0x92
    end
  end

  # ===== Feature 2: Shared Subscriptions CONNACK property =====

  describe "MQTT 5.0 CONNACK properties" do
    test "contains shared_subscription_available", ctx do
      _state = connect_client_v5(ctx, "shared-sub-client")
      drain_mailbox_except_last()

      # The last sent message should be CONNACK
      connack_data = get_last_sent()
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.properties.shared_subscription_available == true
    end

    test "contains topic_alias_maximum", ctx do
      state = connect_client_v5(ctx, "ta-connack-client")
      drain_mailbox_except_last()

      connack_data = get_last_sent()
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.properties.topic_alias_maximum == 100

      # State also has the field
      assert state.server_topic_alias_maximum == 100
    end

    test "contains receive_maximum", ctx do
      _state = connect_client_v5(ctx, "rm-connack-client")
      drain_mailbox_except_last()

      connack_data = get_last_sent()
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.properties.receive_maximum == 65535
    end

    test "advertises maximum_packet_size when configured", ctx do
      {:ok, state} =
        Proto.init(TestHandler,
          [agent: ctx.agent, transport_opts: %{max_packet_size: 1024}],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "mps-client",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, _state} = Proto.handle_data(data, state)

      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.properties.maximum_packet_size == 1024
    end
  end

  # ===== Feature 3: Topic Aliases =====

  describe "topic aliases (MQTT 5.0)" do
    test "PUBLISH with topic_alias + topic stores mapping and routes", ctx do
      state = connect_client_v5(ctx, "ta-store")
      drain_mailbox()

      publish = %{
        type: :publish, topic: "alias/topic", payload: "ta-msg",
        qos: 0, retain: false, dup: false, packet_id: nil,
        properties: %{topic_alias: 1}
      }
      {:ok, data} = Codec.encode(5, publish)
      {:ok, new_state} = Proto.handle_data(data, state)

      events = Agent.get(ctx.agent, & &1)
      assert {:publish, "alias/topic", "ta-msg"} in events
      # Codec normalizes topic to list of segments
      assert new_state.topic_alias_to_topic[1] == ["alias", "topic"]
    end

    test "PUBLISH with topic_alias only uses stored mapping", ctx do
      state = connect_client_v5(ctx, "ta-lookup")
      drain_mailbox()

      # First: store mapping
      publish1 = %{
        type: :publish, topic: "mapped/topic", payload: "first",
        qos: 0, retain: false, dup: false, packet_id: nil,
        properties: %{topic_alias: 5}
      }
      {:ok, data1} = Codec.encode(5, publish1)
      {:ok, state} = Proto.handle_data(data1, state)

      # Second: use alias only (empty topic)
      publish2 = %{
        type: :publish, topic: "", payload: "second",
        qos: 0, retain: false, dup: false, packet_id: nil,
        properties: %{topic_alias: 5}
      }
      {:ok, data2} = Codec.encode(5, publish2)
      {:ok, _state} = Proto.handle_data(data2, state)

      events = Agent.get(ctx.agent, & &1)
      assert {:publish, "mapped/topic", "second"} in events
    end
  end

  # ===== Feature 4: Flow Control (receive_maximum) =====

  describe "flow control (receive_maximum)" do
    test "rejects QoS 2 publish when inflight reaches receive_maximum", ctx do
      {:ok, state} =
        Proto.init(TestHandler,
          [agent: ctx.agent, transport_opts: %{receive_maximum: 2}],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "fc-client",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # QoS 2 Publish 1 — accepted (inflight becomes 1)
      pub1 = %{type: :publish, topic: "fc/t", payload: "1",
               qos: 2, retain: false, dup: false, packet_id: 1, properties: %{}}
      {:ok, d1} = Codec.encode(5, pub1)
      {:ok, state} = Proto.handle_data(d1, state)
      assert_received {:sent, _pubrec1}
      assert state.inflight_count == 1

      # QoS 2 Publish 2 — accepted (inflight becomes 2)
      pub2 = %{pub1 | packet_id: 2, payload: "2"}
      {:ok, d2} = Codec.encode(5, pub2)
      {:ok, state} = Proto.handle_data(d2, state)
      assert_received {:sent, _pubrec2}
      assert state.inflight_count == 2

      # QoS 2 Publish 3 — rejected with 0x93 (inflight at max)
      pub3 = %{pub1 | packet_id: 3, payload: "3"}
      {:ok, d3} = Codec.encode(5, pub3)
      {:ok, _state} = Proto.handle_data(d3, state)

      assert_received {:sent, pubrec3_data}
      {:ok, {pubrec3, <<>>}} = Codec.decode(5, IO.iodata_to_binary(pubrec3_data))
      assert pubrec3.type == :pubrec
      assert pubrec3.reason_code == 0x93
    end

    test "rejects QoS 2 publish when inflight exceeds receive_maximum", ctx do
      {:ok, state} =
        Proto.init(TestHandler,
          [agent: ctx.agent, transport_opts: %{receive_maximum: 1}],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "fc2-client",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # First QoS 2 — accepted
      pub1 = %{type: :publish, topic: "fc/t", payload: "1",
               qos: 2, retain: false, dup: false, packet_id: 1, properties: %{}}
      {:ok, d1} = Codec.encode(5, pub1)
      {:ok, state} = Proto.handle_data(d1, state)
      assert_received {:sent, _pubrec1}

      # Second QoS 2 — should be rejected with 0x93
      pub2 = %{pub1 | packet_id: 2, payload: "2"}
      {:ok, d2} = Codec.encode(5, pub2)
      {:ok, _state} = Proto.handle_data(d2, state)

      assert_received {:sent, pubrec2_data}
      {:ok, {pubrec2, <<>>}} = Codec.decode(5, IO.iodata_to_binary(pubrec2_data))
      assert pubrec2.type == :pubrec
      assert pubrec2.reason_code == 0x93
    end
  end

  # ===== Feature 5: Maximum Packet Size =====

  describe "maximum packet size" do
    test "oversized PUBLISH triggers DISCONNECT 0x95", ctx do
      {:ok, state} =
        Proto.init(TestHandler,
          [agent: ctx.agent, transport_opts: %{max_packet_size: 20}],
          ctx.retained_table, nil, ctx.send_fn)

      # CONNECT is small enough
      connect = %{
        type: :connect, protocol_version: 5, client_id: "mps",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # This PUBLISH is larger than 20 bytes
      publish = %{
        type: :publish, topic: "a/very/long/topic/name", payload: String.duplicate("x", 50),
        qos: 0, retain: false, dup: false, packet_id: nil, properties: %{}
      }
      {:ok, data} = Codec.encode(5, publish)
      {:close, :packet_too_large, new_state} = Proto.handle_data(data, state)

      assert new_state.graceful_disconnect == true

      # Should have sent DISCONNECT with 0x95
      assert_received {:sent, disc_data}
      {:ok, {disc, <<>>}} = Codec.decode(5, IO.iodata_to_binary(disc_data))
      assert disc.type == :disconnect
      assert disc.reason_code == 0x95
    end

    test "outgoing publish exceeding client max is silently dropped", ctx do
      {:ok, state} =
        Proto.init(PublishOnInfoHandler,
          [agent: ctx.agent],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "mps-drop",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{maximum_packet_size: 10}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      assert state.client_max_packet_size == 10

      # Trigger a large outgoing publish via handle_info
      {:noreply, _state} = Proto.handle_info({:send_publish, "big/topic", String.duplicate("x", 100)}, state)

      refute_received {:sent, _}
    end

    test "outgoing publish within client max is sent", ctx do
      {:ok, state} =
        Proto.init(PublishOnInfoHandler,
          [agent: ctx.agent],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "mps-ok",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{maximum_packet_size: 256}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      assert state.client_max_packet_size == 256

      # Trigger a small outgoing publish via handle_info
      {:noreply, _state} = Proto.handle_info({:send_publish, "ok", "hi"}, state)

      assert_received {:sent, _}
    end
  end

  # ===== Feature 6: Server-Initiated DISCONNECT =====

  describe "server-initiated DISCONNECT" do
    test "handle_publish returning {:disconnect, code, state} sends DISCONNECT and closes", ctx do
      {:ok, state} =
        Proto.init(DisconnectOnPublishHandler,
          [agent: ctx.agent],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "disc-pub",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      publish = %{
        type: :publish, topic: "disc/trigger", payload: "bye",
        qos: 0, retain: false, dup: false, packet_id: nil, properties: %{}
      }
      {:ok, data} = Codec.encode(5, publish)
      {:close, {:server_disconnect, 0x8E}, new_state} = Proto.handle_data(data, state)

      assert new_state.graceful_disconnect == true

      # Should have sent DISCONNECT packet
      assert_received {:sent, disc_data}
      {:ok, {disc, <<>>}} = Codec.decode(5, IO.iodata_to_binary(disc_data))
      assert disc.type == :disconnect
      assert disc.reason_code == 0x8E
    end

    test "{:server_disconnect, code, props} via handle_info sends DISCONNECT", ctx do
      state = connect_client_v5(ctx, "disc-info")
      drain_mailbox()

      {:stop, :normal, new_state} = Proto.handle_info({:server_disconnect, 0x98, %{}}, state)
      assert new_state.graceful_disconnect == true

      assert_received {:sent, disc_data}
      {:ok, {disc, <<>>}} = Codec.decode(5, IO.iodata_to_binary(disc_data))
      assert disc.type == :disconnect
      assert disc.reason_code == 0x98
    end

    test "will message NOT published on server-initiated disconnect (graceful)", ctx do
      {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      will = %{topic: "will/topic", payload: "will-msg", qos: 0, retain: false, properties: %{}}
      connect = %{
        type: :connect, protocol_version: 5, client_id: "disc-will",
        username: nil, password: nil, will: will, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      assert state.will_message != nil

      # Server disconnect (graceful)
      {:stop, :normal, new_state} = Proto.handle_info({:server_disconnect, 0x8E, %{}}, state)
      assert new_state.graceful_disconnect == true

      # Handle close after server disconnect
      {:shutdown, _} = Proto.handle_close(new_state)

      # Will message should NOT have been published (graceful disconnect)
      events = Agent.get(ctx.agent, & &1)
      refute Enum.any?(events, fn
        {:publish, "will/topic", _} -> true
        _ -> false
      end)
    end

    test "handle_info {:trigger_disconnect, code} through DisconnectOnPublishHandler", ctx do
      {:ok, state} =
        Proto.init(DisconnectOnPublishHandler,
          [agent: ctx.agent],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "disc-trigger",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      {:stop, :normal, new_state} = Proto.handle_info({:trigger_disconnect, 0x98}, state)
      assert new_state.graceful_disconnect == true

      assert_received {:sent, disc_data}
      {:ok, {disc, <<>>}} = Codec.decode(5, IO.iodata_to_binary(disc_data))
      assert disc.type == :disconnect
      assert disc.reason_code == 0x98
    end
  end

  # ===== AUTH Flow =====

  describe "AUTH flow" do
    test "continue → correct response → CONNACK success", ctx do
      {:ok, state} =
        Proto.init(TestAuthHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      # First, connect the client (v5 required for AUTH)
      connect = %{
        type: :connect, protocol_version: 5, client_id: "auth-ok",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # Send AUTH with nil data → should get {:continue, "challenge-data", state}
      auth1 = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN"}}
      {:ok, data} = Codec.encode(5, auth1)
      {:ok, state} = Proto.handle_data(data, state)

      # Should receive AUTH continue with challenge data
      assert_received {:sent, auth_resp_data}
      {:ok, {auth_resp, <<>>}} = Codec.decode(5, IO.iodata_to_binary(auth_resp_data))
      assert auth_resp.type == :auth
      assert auth_resp.reason_code == 0x18
      assert auth_resp.properties.authentication_data == "challenge-data"

      # Send correct response
      auth2 = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN", authentication_data: "correct-response"}}
      {:ok, data} = Codec.encode(5, auth2)
      {:ok, state} = Proto.handle_data(data, state)

      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.reason_code == 0
      assert state.connected == true
    end

    test "continue response sends AUTH with reason 0x18 and challenge data", ctx do
      {:ok, state} =
        Proto.init(TestAuthHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "auth-continue",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      auth = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN"}}
      {:ok, data} = Codec.encode(5, auth)
      {:ok, _state} = Proto.handle_data(data, state)

      assert_received {:sent, auth_data}
      {:ok, {auth_pkt, <<>>}} = Codec.decode(5, IO.iodata_to_binary(auth_data))
      assert auth_pkt.type == :auth
      assert auth_pkt.reason_code == 0x18
      assert auth_pkt.properties.authentication_method == "PLAIN"
      assert auth_pkt.properties.authentication_data == "challenge-data"
    end

    test "wrong response → CONNACK 0x87, connection closed", ctx do
      {:ok, state} =
        Proto.init(TestAuthHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "auth-fail",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # First get to the continue state
      auth1 = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN"}}
      {:ok, data} = Codec.encode(5, auth1)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      # Send wrong response
      auth2 = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN", authentication_data: "wrong-response"}}
      {:ok, data} = Codec.encode(5, auth2)
      {:close, :auth_failed, _state} = Proto.handle_data(data, state)

      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.reason_code == 0x87
    end

    test "default handle_auth (TestHandler) → CONNACK 0x8C, connection closed", ctx do
      {:ok, state} =
        Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "auth-default",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      auth = %{type: :auth, reason_code: 0x18, properties: %{authentication_method: "PLAIN"}}
      {:ok, data} = Codec.encode(5, auth)
      result = Proto.handle_data(data, state)

      # Default handle_auth returns {:error, 0x8C, state} which means auth not supported
      assert {:close, _, _} = result

      assert_received {:sent, connack_data}
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.reason_code == 0x8C
    end
  end

  # ===== MQTT Compliance Tests =====

  describe "pre-CONNECT packet rejection" do
    test "rejects PUBLISH before CONNECT with protocol error", ctx do
      {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

      publish = %{
        type: :publish, topic: "test/topic", payload: "hello",
        qos: 0, retain: false, dup: false, packet_id: nil, properties: %{}
      }

      {:ok, data} = Codec.encode(4, publish)
      {:close, :protocol_error, _state} = Proto.handle_data(data, state)
    end
  end

  describe "topic alias validation" do
    test "rejects topic alias exceeding server maximum with DISCONNECT 0x94", ctx do
      state = connect_client_v5(ctx, "ta-invalid")
      drain_mailbox()

      publish = %{
        type: :publish, topic: "some/topic", payload: "msg",
        qos: 0, retain: false, dup: false, packet_id: nil,
        properties: %{topic_alias: 200}
      }

      {:ok, data} = Codec.encode(5, publish)
      {:close, {:server_disconnect, 0x94}, new_state} = Proto.handle_data(data, state)

      assert new_state.graceful_disconnect == true

      assert_received {:sent, disc_data}
      {:ok, {disc, <<>>}} = Codec.decode(5, IO.iodata_to_binary(disc_data))
      assert disc.type == :disconnect
      assert disc.reason_code == 0x94
    end

    test "rejects topic alias of 0 with DISCONNECT 0x94", ctx do
      state = connect_client_v5(ctx, "ta-zero")
      drain_mailbox()

      publish = %{
        type: :publish, topic: "some/topic", payload: "msg",
        qos: 0, retain: false, dup: false, packet_id: nil,
        properties: %{topic_alias: 0}
      }

      {:ok, data} = Codec.encode(5, publish)
      {:close, {:server_disconnect, 0x94}, _state} = Proto.handle_data(data, state)
    end
  end

  describe "property forwarding in send_publish" do
    test "forwards MQTT 5.0 properties through send_publish", ctx do
      {:ok, state} =
        Proto.init(PublishOnInfoHandler,
          [agent: ctx.agent],
          ctx.retained_table, nil, ctx.send_fn)

      connect = %{
        type: :connect, protocol_version: 5, client_id: "prop-fwd",
        username: nil, password: nil, will: nil, clean_session: true,
        keep_alive: 0, properties: %{}
      }
      {:ok, data} = Codec.encode(5, connect)
      {:ok, state} = Proto.handle_data(data, state)
      drain_mailbox()

      opts = %{qos: 0, retain: false, properties: %{user_properties: [{"key", "val"}]}}
      {:noreply, _state} = Proto.handle_info({:send_publish, "prop/topic", "data", opts}, state)

      assert_received {:sent, pub_data}
      {:ok, {pub, <<>>}} = Codec.decode(5, IO.iodata_to_binary(pub_data))
      assert pub.type == :publish
      assert pub.properties.user_properties == [{"key", "val"}]
    end
  end

  describe "CONNACK capability properties" do
    test "contains retain_available, wildcard_subscription_available, subscription_identifier_available", ctx do
      _state = connect_client_v5(ctx, "cap-props")
      drain_mailbox_except_last()

      connack_data = get_last_sent()
      {:ok, {connack, <<>>}} = Codec.decode(5, IO.iodata_to_binary(connack_data))
      assert connack.type == :connack
      assert connack.properties.retain_available == true
      assert connack.properties.wildcard_subscription_available == true
      assert connack.properties.subscription_identifier_available == false
    end
  end

  describe "retain_handling" do
    test "retain_handling 2 suppresses retained message delivery", ctx do
      state = connect_client_v5(ctx, "rh-test")
      drain_mailbox()

      # Insert a retained message
      :ets.insert(ctx.retained_table, {"rh/topic", ["rh", "topic"], "retained-payload", 0, System.system_time(:second), nil})

      # Subscribe with retain_handling: 2 (don't send retained)
      subscribe = %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "rh/topic", qos: 0, retain_handling: 2}],
        properties: %{}
      }

      {:ok, data} = Codec.encode(5, subscribe)
      {:ok, _state} = Proto.handle_data(data, state)

      # Should get SUBACK but no retained PUBLISH
      assert_received {:sent, suback_data}
      {:ok, {suback, <<>>}} = Codec.decode(5, IO.iodata_to_binary(suback_data))
      assert suback.type == :suback

      refute_received {:sent, _}
    end

    test "retain_handling 0 sends retained message normally", ctx do
      state = connect_client_v5(ctx, "rh0-test")
      drain_mailbox()

      # Insert a retained message
      :ets.insert(ctx.retained_table, {"rh0/topic", ["rh0", "topic"], "retained-payload", 0, System.system_time(:second), nil})

      # Subscribe with retain_handling: 0 (send retained)
      subscribe = %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "rh0/topic", qos: 0, retain_handling: 0}],
        properties: %{}
      }

      {:ok, data} = Codec.encode(5, subscribe)
      {:ok, _state} = Proto.handle_data(data, state)

      # Should get SUBACK + retained PUBLISH
      assert_received {:sent, _suback_data}
      assert_received {:sent, pub_data}
      {:ok, {pub, <<>>}} = Codec.decode(5, IO.iodata_to_binary(pub_data))
      assert pub.type == :publish
      assert pub.payload == "retained-payload"
    end
  end

  # ===== Helpers =====

  defp connect_client(ctx, client_id) do
    {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

    connect = %{
      type: :connect, protocol_version: 4, client_id: client_id,
      username: nil, password: nil, will: nil, clean_session: true,
      keep_alive: 0, properties: %{}
    }

    {:ok, data} = Codec.encode(4, connect)
    {:ok, state} = Proto.handle_data(data, state)
    state
  end

  defp connect_client_v5(ctx, client_id) do
    {:ok, state} = Proto.init(TestHandler, [agent: ctx.agent], ctx.retained_table, nil, ctx.send_fn)

    connect = %{
      type: :connect, protocol_version: 5, client_id: client_id,
      username: nil, password: nil, will: nil, clean_session: true,
      keep_alive: 0, properties: %{}
    }

    {:ok, data} = Codec.encode(5, connect)
    {:ok, state} = Proto.handle_data(data, state)
    state
  end

  defp drain_mailbox do
    receive do
      {:sent, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp drain_mailbox_except_last do
    receive do
      {:sent, _} = msg ->
        receive do
          {:sent, _} = next ->
            # Put next back conceptually — but we can't. Instead, drain all and track last.
            drain_and_keep_last(next)
        after
          0 ->
            # msg is the last one, put it back
            send(self(), msg)
        end
    after
      0 -> :ok
    end
  end

  defp drain_and_keep_last(last) do
    receive do
      {:sent, _} = next -> drain_and_keep_last(next)
    after
      0 -> send(self(), last)
    end
  end

  defp get_last_sent do
    receive do
      {:sent, data} -> data
    after
      100 -> raise "No sent data in mailbox"
    end
  end
end
