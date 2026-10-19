defmodule MqttX.Transport.HandlerSessionTest do
  @moduledoc """
  Server-side Session State (MQTT §4.1): a session outlives its connection,
  is resumed with Clean Start 0, and receives what `MqttX.Server.deliver/3`
  sent it while it was away. Drives `MqttX.Transport.Handler` directly with
  one `MqttX.Server.SessionStore` shared by successive connections, the way a
  listener shares it.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Server.RetainedStore
  alias MqttX.Server.SessionStore
  alias MqttX.Transport.Handler, as: Proto

  defmodule Recorder do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_connect(client_id, _credentials, connect_info, state) do
      send(state.notify, {:handle_connect, client_id, connect_info})
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
    def handle_disconnect(_reason, _state), do: :ok

    @impl true
    def handle_session_expired(client_id, state) do
      send(state.notify, {:session_expired, client_id})
      :ok
    end

    @impl true
    def handle_info({:send_publish, topic, payload, opts}, state),
      do: {:publish, topic, payload, opts, state}

    # MqttX.Server.deliver/3 from inside a callback
    def handle_info({:deliver, topic, payload, opts}, state) do
      send(state.notify, {:delivered, MqttX.Server.deliver(topic, payload, opts)})
      {:ok, state}
    end
  end

  setup do
    store = SessionStore.new()
    retained = RetainedStore.new_table()
    send_fn = fn data -> send(self(), {:sent, data}) end
    {:ok, store: store, retained: retained, send_fn: send_fn}
  end

  # ---------- helpers ----------

  defp init(ctx, transport_opts) do
    opts = [notify: self(), transport_opts: transport_opts]
    {:ok, state} = Proto.init(Recorder, opts, ctx.retained, nil, ctx.send_fn, ctx.store)
    state
  end

  defp connect_packet(client_id, version, extra) do
    Map.merge(
      %{
        type: :connect,
        protocol_version: version,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: %{}
      },
      extra
    )
  end

  # A CONNECT with Clean Start 0 and a Session Expiry Interval, so the session
  # survives the connection
  defp persistent_connect(client_id, sei \\ 300),
    do:
      connect_packet(client_id, 5, %{
        clean_session: false,
        properties: %{session_expiry_interval: sei}
      })

  defp publish(topic, payload, qos, packet_id, props \\ %{}) do
    %{
      type: :publish,
      topic: topic,
      payload: payload,
      qos: qos,
      retain: false,
      dup: false,
      packet_id: packet_id,
      properties: props
    }
  end

  defp ack(type, packet_id),
    do: %{type: type, packet_id: packet_id, reason_code: 0, properties: %{}}

  defp encode(version, packet) do
    {:ok, data} = Codec.encode(version, packet)
    data
  end

  # Encoded in the connection's protocol version (v5 before CONNECT)
  defp feed(state, packet, version \\ nil) do
    version = version || state.protocol_version || 5
    {:ok, state} = Proto.handle_data(encode(version, packet), state)
    state
  end

  defp decode(version, data) do
    {:ok, {packet, <<>>}} = Codec.decode(version, IO.iodata_to_binary(data))
    packet
  end

  defp sent(version \\ 5) do
    assert_received {:sent, data}
    decode(version, data)
  end

  # Everything sent so far, in order
  defp sent_all(version \\ 5) do
    receive do
      {:sent, data} -> [decode(version, data) | sent_all(version)]
    after
      0 -> []
    end
  end

  defp drain do
    receive do
      {:sent, _} -> drain()
      :mqttx_drain -> drain()
      {:mqttx_deliver, _, _, _, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  # Apply what MqttX.Server.deliver/3 sent straight to this connection (one
  # whose session ends with it). Every connection here shares the test
  # process's mailbox, so the messages are picked out by client id.
  defp delivered(state) do
    client_id = state.client_id

    receive do
      {:mqttx_deliver, ^client_id, _, _, _, _} = msg ->
        {:noreply, state} = Proto.handle_info(msg, state)
        delivered(state)
    after
      0 -> state
    end
  end

  # Connect and return {state, connack}
  defp connect(ctx, packet, transport_opts \\ %{}) do
    version = packet.protocol_version
    state = feed(init(ctx, transport_opts), packet, version)
    connack = sent(version)
    assert %{type: :connack, reason_code: 0} = connack
    {state, connack}
  end

  defp subscribe(state, filter, qos, props \\ %{}, extra \\ %{}) do
    topic = Map.merge(%{topic: filter, qos: qos}, extra)
    state = feed(state, %{type: :subscribe, packet_id: 1, topics: [topic], properties: props})
    assert %{type: :suback} = sent(state.protocol_version)
    state
  end

  # The connection is gone (socket closed) — the session outlives it or not
  defp close(state) do
    {:shutdown, state} = Proto.handle_close(state)
    drain()
    state
  end

  # What MqttX.Server.deliver/3 poked us about
  defp drained(state) do
    {:noreply, state} = Proto.handle_info(:mqttx_drain, state)
    state
  end

  defp publishes(packets), do: for(%{type: :publish} = p <- packets, do: p)

  # ---------- Tier 1: the session survives the connection ----------

  describe "session presence (§3.1.2.4, MQTT-3.2.2-2/-3)" do
    test "Clean Start 0 resumes a stored session; Clean Start 1 discards it", ctx do
      {s, connack} = connect(ctx, persistent_connect("c"))
      refute connack.session_present
      assert_received {:handle_connect, "c", %{session_present: false, subscriptions: []}}

      s = subscribe(s, "a/#", 1)
      close(s)
      assert SessionStore.exists?(ctx.store, "c")

      {s, connack} = connect(ctx, persistent_connect("c"))
      assert connack.session_present
      assert s.session_present

      assert_received {:handle_connect, "c",
                       %{session_present: true, subscriptions: [%{topic: "a/#", qos: 1}]}}

      # The subscription is live again: an application publish routes through it
      {:noreply, s} = Proto.handle_info({:send_publish, "a/x", "hi", %{qos: 2}}, s)
      assert %{type: :publish, topic: ["a", "x"], qos: 1} = sent()
      assert MapSet.member?(s.subscribed_filters, "a/#")
      close(s)

      {_s, connack} = connect(ctx, connect_packet("c", 5, %{clean_session: true}))
      refute connack.session_present
      assert_received {:handle_connect, "c", %{session_present: false, subscriptions: []}}
      assert SessionStore.subscriptions(ctx.store, "c") == []
    end

    test "a session with Session Expiry Interval 0 (or none) ends with the connection", ctx do
      {s, _} = connect(ctx, connect_packet("ephemeral", 5, %{clean_session: false}))
      s = subscribe(s, "a/#", 1)
      assert SessionStore.exists?(ctx.store, "ephemeral")

      close(s)
      refute SessionStore.exists?(ctx.store, "ephemeral")

      {_s, connack} = connect(ctx, connect_packet("ephemeral", 5, %{clean_session: false}))
      refute connack.session_present
    end

    test "a 3.1.1 client with CleanSession 0 keeps its session, bounded by the listener's maximum",
         ctx do
      {s, _} = connect(ctx, connect_packet("legacy", 4, %{clean_session: false}))
      assert s.session_lifetime == 86_400
      s = subscribe(s, "a/#", 1)
      close(s)

      {s, connack} = connect(ctx, connect_packet("legacy", 4, %{clean_session: false}))
      assert connack.session_present
      assert MapSet.member?(s.subscribed_filters, "a/#")
      close(s)

      {_s, connack} = connect(ctx, connect_packet("legacy", 4, %{clean_session: true}))
      refute connack.session_present
    end

    test "the CONNACK carries the Session Expiry Interval when the listener shortens it (§3.2.2.3.2)",
         ctx do
      opts = %{max_session_expiry_interval: 60}

      {s, connack} = connect(ctx, persistent_connect("capped", 3600), opts)
      assert connack.properties.session_expiry_interval == 60
      assert s.session_lifetime == 60

      {_s, connack} = connect(ctx, persistent_connect("under", 30), opts)
      refute Map.has_key?(connack.properties, :session_expiry_interval)

      {_s, connack} = connect(ctx, persistent_connect("forever", 0xFFFFFFFF), opts)
      assert connack.properties.session_expiry_interval == 60
    end

    test "a Session Expiry Interval revised on DISCONNECT is honored", ctx do
      {s, _} = connect(ctx, persistent_connect("revise", 300))
      s = subscribe(s, "a/#", 1)

      disconnect = %{type: :disconnect, reason_code: 0, properties: %{session_expiry_interval: 0}}
      {:close, :disconnect, _} = Proto.handle_data(encode(5, disconnect), s)

      refute SessionStore.exists?(ctx.store, "revise")
    end
  end

  describe "session expiry" do
    test "the session is discarded when its interval elapses, and the handler is told", ctx do
      {s, _} = connect(ctx, persistent_connect("short-lived", 1))
      s = subscribe(s, "a/#", 1)
      close(s)
      assert SessionStore.exists?(ctx.store, "short-lived")

      assert_receive {:session_expired, "short-lived"}, 2_000
      refute SessionStore.exists?(ctx.store, "short-lived")
      assert SessionStore.match(ctx.store, "a/b") == []
    end

    test "reconnecting before expiry cancels it", ctx do
      {s, _} = connect(ctx, persistent_connect("quick", 1))
      close(s)

      {_s, connack} = connect(ctx, persistent_connect("quick", 300))
      assert connack.session_present

      refute_receive {:session_expired, "quick"}, 1_500
      assert SessionStore.exists?(ctx.store, "quick")
    end
  end

  describe "in-flight QoS 1/2 state across a reconnect (§4.4, MQTT-4.4.0-1)" do
    test "unacknowledged PUBLISHes are re-sent with DUP, a sent PUBREL is re-sent, a held inbound QoS 2 completes",
         ctx do
      {s, _} = connect(ctx, persistent_connect("inflight"))

      # Outbound QoS 1, never acknowledged
      {:noreply, s} = Proto.handle_info({:send_publish, "t", "q1", %{qos: 1}}, s)
      %{type: :publish, packet_id: q1_id} = sent()

      # Outbound QoS 2, PUBREC received so PUBREL went out, PUBCOMP never came
      {:noreply, s} = Proto.handle_info({:send_publish, "t", "q2", %{qos: 2}}, s)
      %{type: :publish, packet_id: q2_id} = sent()
      s = feed(s, ack(:pubrec, q2_id))
      assert %{type: :pubrel, packet_id: ^q2_id} = sent()

      # Outbound QoS 2, no PUBREC yet
      {:noreply, s} = Proto.handle_info({:send_publish, "t", "q2b", %{qos: 2}}, s)
      %{type: :publish, packet_id: q2b_id} = sent()

      # Inbound QoS 2 from the client, PUBREC sent, PUBREL never came
      s = feed(s, publish("in/t", "held", 2, 7))
      assert %{type: :pubrec, packet_id: 7} = sent()
      refute_received {:handle_publish, _, _}
      assert length(SessionStore.inflight(ctx.store, "inflight")) == 4

      close(s)

      {s, connack} = connect(ctx, persistent_connect("inflight"))
      assert connack.session_present
      resent = sent_all()

      assert [
               %{type: :publish, packet_id: ^q1_id, payload: "q1", dup: true, qos: 1},
               %{type: :pubrel, packet_id: ^q2_id},
               %{type: :publish, packet_id: ^q2b_id, payload: "q2b", dup: true, qos: 2}
             ] = resent

      # The flows then complete as on a live connection
      s = feed(s, ack(:puback, q1_id))
      s = feed(s, ack(:pubcomp, q2_id))
      s = feed(s, ack(:pubrec, q2b_id))
      assert %{type: :pubrel, packet_id: ^q2b_id} = sent()
      s = feed(s, ack(:pubcomp, q2b_id))
      assert s.pending_qos1_tx == %{}
      assert s.pending_qos2_tx == %{}

      s = feed(s, ack(:pubrel, 7))
      assert_received {:handle_publish, "in/t", "held"}
      assert %{type: :pubcomp, packet_id: 7} = sent()
      assert s.pending_qos2_rx == %{}
      assert s.inflight_count == 0
      assert SessionStore.inflight(ctx.store, "inflight") == []
    end

    test "acknowledged messages are not re-sent, and nothing is mirrored for a non-persistent session",
         ctx do
      {s, _} = connect(ctx, persistent_connect("acked"))
      {:noreply, s} = Proto.handle_info({:send_publish, "t", "q1", %{qos: 1}}, s)
      %{type: :publish, packet_id: id} = sent()
      s = feed(s, ack(:puback, id))
      close(s)

      {_s, connack} = connect(ctx, persistent_connect("acked"))
      assert connack.session_present
      assert sent_all() == []

      {s, _} = connect(ctx, connect_packet("plain", 5, %{}))
      {:noreply, _s} = Proto.handle_info({:send_publish, "t", "q1", %{qos: 1}}, s)
      assert %{type: :publish} = sent()
      assert SessionStore.inflight(ctx.store, "plain") == []
    end

    test "a new connection taking the session over inherits it intact (§3.1.4)", ctx do
      {old, _} = connect(ctx, persistent_connect("taken"))
      old = subscribe(old, "a/#", 1)
      {:noreply, old} = Proto.handle_info({:send_publish, "a/1", "pending", %{qos: 1}}, old)
      %{type: :publish, packet_id: id} = sent()

      # Both connections live in this process, so the handshake is skipped;
      # the incumbent's reaction to the notice is what matters here
      {:stop, :normal, old} = Proto.handle_info({:server_disconnect, 0x8E, %{}}, old)
      assert %{type: :disconnect, reason_code: 0x8E} = sent()
      {:shutdown, _} = Proto.handle_close(old)

      {new, connack} = connect(ctx, persistent_connect("taken"))
      assert connack.session_present
      assert [%{type: :publish, packet_id: ^id, payload: "pending", dup: true}] = sent_all()
      assert MapSet.member?(new.subscribed_filters, "a/#")
    end
  end

  # ---------- Tier 2: MqttX.Server.deliver/3 ----------

  describe "MqttX.Server.deliver/3 to connected sessions" do
    test "reaches every matching subscriber with its subscription's options", ctx do
      {c1, _} = connect(ctx, connect_packet("c1", 5, %{}))
      c1 = subscribe(c1, "s/#", 1, %{subscription_identifier: 9})
      {c2, _} = connect(ctx, connect_packet("c2", 5, %{}))
      c2 = subscribe(c2, "s/+", 0, %{}, %{retain_as_published: true})
      {c3, _} = connect(ctx, connect_packet("c3", 5, %{}))
      c3 = subscribe(c3, "other", 2)

      # From inside a handler callback (c3's), as an application would
      {:noreply, _c3} =
        Proto.handle_info({:deliver, "s/x", "hello", %{qos: 1, retain: true}}, c3)

      assert_received {:delivered, {:ok, 2}}

      # These sessions end with their connections, so the message came
      # straight to the connection, not through the store
      assert SessionStore.queue_length(ctx.store, "c1") == 0
      c1 = delivered(c1)

      assert [%{type: :publish, topic: ["s", "x"], payload: "hello", qos: 1, retain: false} = p1] =
               publishes(sent_all())

      assert p1.properties.subscription_identifier == 9

      _c2 = delivered(c2)
      assert [%{type: :publish, topic: ["s", "x"], qos: 0, retain: true}] = publishes(sent_all())

      _c3 = delivered(c3)
      assert sent_all() == []
      assert c1.pending_qos1_tx |> map_size() == 1
    end

    test "a connected persistent session is served through its queue", ctx do
      {c, _} = connect(ctx, persistent_connect("durable"))
      c = subscribe(c, "d/#", 1)

      assert {:ok, 1} = MqttX.Server.deliver("d/1", "queued first", %{qos: 1})
      assert SessionStore.queue_length(ctx.store, "durable") == 1
      assert_received :mqttx_drain

      _c = drained(c)

      assert [%{type: :publish, topic: ["d", "1"], payload: "queued first", qos: 1}] =
               publishes(sent_all())

      assert SessionStore.queue_length(ctx.store, "durable") == 0
    end

    test "honors no_local through :publisher and rejects an invalid topic", ctx do
      {c1, _} = connect(ctx, connect_packet("me", 5, %{}))
      _c1 = subscribe(c1, "n", 0, %{}, %{no_local: true})

      assert {:ok, 0} = MqttX.Server.deliver("n", "x", %{publisher: "me"})
      assert {:ok, 1} = MqttX.Server.deliver("n", "x", %{publisher: "someone-else"})
      assert {:error, :invalid_topic} = MqttX.Server.deliver("n/#", "x", %{})
    end

    test "waits for the client's Receive Maximum window (§3.3.4)", ctx do
      {c, _} = connect(ctx, connect_packet("narrow", 5, %{properties: %{receive_maximum: 1}}))
      c = subscribe(c, "w/#", 1)

      assert {:ok, 1} = MqttX.Server.deliver("w/1", "first", %{qos: 1})
      assert {:ok, 1} = MqttX.Server.deliver("w/2", "second", %{qos: 1})

      c = delivered(c)
      assert [%{type: :publish, payload: "first", packet_id: id}] = publishes(sent_all())
      assert :queue.len(c.outbound_queue) == 1

      c = feed(c, ack(:puback, id))
      assert [%{type: :publish, payload: "second"}] = publishes(sent_all())
      assert :queue.len(c.outbound_queue) == 0
    end
  end

  describe "MqttX.Server.deliver/3 to a session that is not connected" do
    test "QoS 1/2 messages are queued and delivered in order on reconnect; QoS 0 is not", ctx do
      {s, _} = connect(ctx, persistent_connect("away"))
      s = subscribe(s, "q/#", 2)
      close(s)

      assert {:ok, 1} = MqttX.Server.deliver("q/1", "one", %{qos: 1})
      assert {:ok, 1} = MqttX.Server.deliver("q/2", "two", %{qos: 2})
      assert {:ok, 0} = MqttX.Server.deliver("q/3", "zero", %{qos: 0})
      assert {:ok, 0} = MqttX.Server.deliver("elsewhere", "no", %{qos: 1})
      assert SessionStore.queue_length(ctx.store, "away") == 2

      {_s, connack} = connect(ctx, persistent_connect("away"))
      assert connack.session_present

      assert [
               %{type: :publish, topic: ["q", "1"], payload: "one", qos: 1},
               %{type: :publish, topic: ["q", "2"], payload: "two", qos: 2}
             ] = publishes(sent_all())

      assert SessionStore.queue_length(ctx.store, "away") == 0
    end

    test "nothing is queued for a client without a session", ctx do
      {s, _} = connect(ctx, connect_packet("gone", 5, %{}))
      s = subscribe(s, "q/#", 1)
      close(s)

      assert {:ok, 0} = MqttX.Server.deliver("q/1", "one", %{qos: 1})
    end

    test "the queue is bounded by :max_outbound_queue", ctx do
      opts = %{max_outbound_queue: 2}
      {s, _} = connect(ctx, persistent_connect("bounded"), opts)
      s = subscribe(s, "b/#", 1)
      close(s)

      assert {:ok, 1} = MqttX.Server.deliver("b/1", "1", %{qos: 1})
      assert {:ok, 1} = MqttX.Server.deliver("b/2", "2", %{qos: 1})
      assert {:ok, 0} = MqttX.Server.deliver("b/3", "3", %{qos: 1})

      {_s, _} = connect(ctx, persistent_connect("bounded"), opts)
      assert ["1", "2"] = sent_all() |> publishes() |> Enum.map(& &1.payload)
    end

    test "Message Expiry keeps counting while queued (MQTT-3.3.2-6)", ctx do
      {s, _} = connect(ctx, persistent_connect("expiring"))
      s = subscribe(s, "e/#", 1)
      close(s)

      props_short = %{message_expiry_interval: 1}
      props_long = %{message_expiry_interval: 100}
      assert {:ok, 1} = MqttX.Server.deliver("e/1", "short", %{qos: 1, properties: props_short})
      assert {:ok, 1} = MqttX.Server.deliver("e/2", "long", %{qos: 1, properties: props_long})

      Process.sleep(1_100)

      {_s, _} = connect(ctx, persistent_connect("expiring"))

      assert [%{payload: "long", properties: %{message_expiry_interval: remaining}}] =
               publishes(sent_all())

      assert remaining in 98..99
    end

    test "what was waiting for the Receive Maximum window when the connection dropped is kept",
         ctx do
      {c, _} = connect(ctx, persistent_connect("window"), %{})

      c =
        feed(c, %{
          type: :subscribe,
          packet_id: 1,
          topics: [%{topic: "w/#", qos: 1}],
          properties: %{}
        })

      drain()

      # Receive Maximum 1 from the client: the second publish waits in-process
      c = %{c | client_receive_maximum: 1}
      {:noreply, c} = Proto.handle_info({:send_publish, "w/1", "sent", %{qos: 1}}, c)
      {:noreply, c} = Proto.handle_info({:send_publish, "w/2", "waiting", %{qos: 1}}, c)
      assert [%{payload: "sent", packet_id: id}] = publishes(sent_all())
      close(c)

      {_c, _} = connect(ctx, persistent_connect("window"))

      assert [
               %{payload: "sent", packet_id: ^id, dup: true},
               %{payload: "waiting", dup: false}
             ] = publishes(sent_all())
    end
  end
end
