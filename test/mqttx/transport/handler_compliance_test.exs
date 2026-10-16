defmodule MqttX.Transport.HandlerComplianceTest do
  @moduledoc """
  Broker-side fixes from the MQTT 5.0 / 3.1.1 conformance audit, each pinned
  to the normative statement it satisfies. Drives `MqttX.Transport.Handler`
  directly, as `handler_test.exs` does.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Server.RetainedStore
  alias MqttX.Transport.Handler, as: Proto

  defmodule Recorder do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts),
      do: %{notify: Keyword.fetch!(opts, :notify), grants: Keyword.get(opts, :grants)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_connect(client_id, _credentials, connect_info, state) do
      send(state.notify, {:handle_connect, client_id, connect_info})
      {:ok, state}
    end

    @impl true
    def handle_publish(_topic, "reject", _opts, state), do: {:error, :unauthorized, state}
    def handle_publish(_topic, "reject-code", _opts, state), do: {:error, 0x97, state}

    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:handle_publish, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, %{grants: nil} = state),
      do: {:ok, Enum.map(topics, & &1.qos), state}

    def handle_subscribe(_topics, %{grants: grants} = state), do: {:ok, grants, state}

    @impl true
    def handle_disconnect(reason, state) do
      send(state.notify, {:handle_disconnect, reason})
      :ok
    end

    @impl true
    def handle_info({:send_publish, topic, payload, opts}, state),
      do: {:publish, topic, payload, opts, state}

    def handle_info({:kick, code, props}, state), do: {:disconnect, code, props, state}

    @impl true
    def handle_auth("TOY", nil, state), do: {:continue, "nonce", state}
    def handle_auth("TOY", "proof", state), do: {:ok, state}
    def handle_auth(_method, _data, state), do: {:error, 0x87, state}
  end

  # Refuses every CONNECT with the configured reason code
  defmodule Refuser do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{code: Keyword.fetch!(opts, :code)}
    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:error, state.code, state}
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

  defp init(ctx, opts \\ []) do
    {:ok, state} =
      Proto.init(Recorder, Keyword.merge([notify: self()], opts), ctx.retained, nil, ctx.send_fn)

    state
  end

  defp connect(client_id, version \\ 5, extra \\ %{}) do
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

  defp subscribe(packet_id, topics, props \\ %{}) do
    %{type: :subscribe, packet_id: packet_id, topics: topics, properties: props}
  end

  defp encode(version, packet) do
    {:ok, data} = Codec.encode(version, packet)
    data
  end

  defp feed(state, version, packet) do
    {:ok, state} = Proto.handle_data(encode(version, packet), state)
    state
  end

  defp sent(version \\ 5) do
    assert_received {:sent, data}
    {:ok, {packet, <<>>}} = Codec.decode(version, IO.iodata_to_binary(data))
    packet
  end

  defp sent_all(version \\ 5) do
    receive do
      {:sent, _} = msg ->
        send(self(), msg)
        [sent(version) | sent_all(version)]
    after
      0 -> []
    end
  end

  defp drain do
    receive do
      {:sent, _} -> drain()
    after
      0 -> :ok
    end
  end

  defp connected(ctx, client_id, version \\ 5, extra \\ %{}, opts \\ []) do
    state = feed(init(ctx, opts), version, connect(client_id, version, extra))
    assert %{type: :connack, reason_code: 0} = sent(version)
    state
  end

  defp subscribed(state, filter, qos, props \\ %{}) do
    state = feed(state, 5, subscribe(1, [%{topic: filter, qos: qos}], props))
    drain()
    state
  end

  describe "a QoS 1 PUBLISH the handler refuses (MQTT-3.3.4-1, MQTT-4.3.2-4)" do
    test "is still acknowledged — PUBACK with a refusal code on v5", ctx do
      state = connected(ctx, "refuse-v5")

      state = feed(state, 5, publish("t", "reject", 1, 7))
      assert %{type: :puback, packet_id: 7, reason_code: 0x87} = sent()

      # An integer that is itself a PUBACK code passes through
      _ = feed(state, 5, publish("t", "reject-code", 1, 8))
      assert %{type: :puback, packet_id: 8, reason_code: 0x97} = sent()
      refute_received {:handle_publish, _, _}
    end

    test "is still acknowledged with a plain PUBACK on v3.1.1", ctx do
      state = connected(ctx, "refuse-v4", 4)
      _ = feed(state, 4, publish("t", "reject", 1, 7))
      assert %{type: :puback, packet_id: 7} = sent(4)
    end
  end

  describe "UNSUBACK (§3.11.3)" do
    test "answers 0x11 No subscription existed for a filter that was never subscribed", ctx do
      state = connected(ctx, "unsub") |> subscribed("a/b", 0)

      _ =
        feed(state, 5, %{
          type: :unsubscribe,
          packet_id: 2,
          topics: ["a/b", "never/x"],
          properties: %{}
        })

      assert %{type: :unsuback, packet_id: 2, acks: [{:ok, :found}, {:ok, :notfound}]} = sent()
    end
  end

  describe "zero-length Client Identifier (§3.1.3.1)" do
    test "v5: the broker assigns one and advertises it in CONNACK", ctx do
      state = feed(init(ctx), 5, connect(""))

      assert %{type: :connack, reason_code: 0, properties: %{assigned_client_identifier: id}} =
               sent()

      assert is_binary(id) and byte_size(id) > 0
      # The handler and the connection run under the assigned id, not ""
      assert_received {:handle_connect, ^id, _info}
      assert state.client_id == id
    end

    test "v3.1.1: the broker still assigns one internally (there is no CONNACK property)", ctx do
      state = feed(init(ctx), 4, connect("", 4))
      assert %{type: :connack, reason_code: 0} = sent(4)
      assert_received {:handle_connect, id, _info}
      assert is_binary(id) and id != ""
      assert state.client_id == id
    end
  end

  describe "CONNECT refused by the handler (3.1.1 §3.2.2.3, MQTT-3.2.2-8)" do
    defp refused(ctx, version, code) do
      {:ok, state} = Proto.init(Refuser, [code: code], ctx.retained, nil, ctx.send_fn)

      assert {:close, :auth_failed, _} =
               Proto.handle_data(encode(version, connect("c", version)), state)

      %{type: :connack, reason_code: rc} = sent(version)
      rc
    end

    test "v5 reason codes reach a 3.1.1 client as return codes 1..5", ctx do
      assert refused(ctx, 4, 0x86) == 4
      assert refused(ctx, 4, 0x87) == 5
      assert refused(ctx, 4, 0x85) == 2
      assert refused(ctx, 4, 0x88) == 3
      assert refused(ctx, 4, 0x84) == 1
      # A handler already speaking 3.1.1 return codes is left alone
      assert refused(ctx, 4, 5) == 5
    end

    test "a v5 CONNACK only carries CONNACK reason codes", ctx do
      assert refused(ctx, 5, 0x87) == 0x87
      # 0x8E Session taken over is a DISCONNECT code
      assert refused(ctx, 5, 0x8E) == 0x80
    end
  end

  describe "Will on a server-initiated close (§3.1.2.5, §3.1.4)" do
    @will %{topic: "will/t", payload: "bye", qos: 0, retain: false, properties: %{}}

    test "a handler's {:disconnect, ...} publishes the Will", ctx do
      state = connected(ctx, "kicked", 5, %{will: @will})
      {:stop, :normal, state} = Proto.handle_info({:kick, 0x98, %{}}, state)
      refute state.graceful_disconnect

      {:shutdown, _} = Proto.handle_close(state)
      assert_received {:handle_publish, "will/t", "bye"}
    end

    test "session takeover publishes an immediate Will", ctx do
      state = connected(ctx, "taken", 5, %{will: @will})
      {:stop, :normal, state} = Proto.handle_info({:server_disconnect, 0x8E, %{}}, state)
      {:shutdown, _} = Proto.handle_close(state)
      assert_received {:handle_publish, "will/t", "bye"}
    end

    test "session takeover drops a delayed Will and does not start session expiry", ctx do
      delayed = %{@will | properties: %{will_delay_interval: 5}}

      state =
        connected(ctx, "taken-delayed", 5, %{
          will: delayed,
          properties: %{session_expiry_interval: 60}
        })

      {:stop, :normal, state} = Proto.handle_info({:server_disconnect, 0x8E, %{}}, state)
      # The new connection owns the session: no Will, nothing left to expire
      assert state.will_message == nil
      assert state.session_expiry_interval == nil

      {:shutdown, _} = Proto.handle_close(state)
      refute_received {:handle_publish, "will/t", _}
    end
  end

  describe "Will Delay (§3.1.3.2.2, MQTT-3.1.3-9)" do
    @tag timeout: 10_000
    test "a reconnect within the delay cancels the delayed Will; without one it fires", ctx do
      delayed = %{@will | properties: %{will_delay_interval: 1}}
      extra = %{will: delayed, properties: %{session_expiry_interval: 60}}

      # Dropped, then back within a second: no Will
      state = connected(ctx, "wd-back", 5, extra)
      {:shutdown, _} = Proto.handle_close(state)
      _ = connected(ctx, "wd-back", 5, extra)

      # Dropped and gone: the Will fires after the delay
      state = connected(ctx, "wd-gone", 5, extra)
      {:shutdown, _} = Proto.handle_close(state)

      assert_receive {:handle_publish, "will/t", "bye"}, 3_000
      refute_received {:handle_publish, "will/t", _}
    end
  end

  describe "AUTH on a live connection (§3.15.2.1, §3.15.2.2.2)" do
    defp auth_connected(ctx, client_id) do
      extra = %{properties: %{authentication_method: "TOY", authentication_data: "proof"}}
      connected(ctx, client_id, 5, extra)
    end

    test "a reason code other than 0x18/0x19 is a Protocol Error", ctx do
      state = auth_connected(ctx, "auth-rc")
      auth = %{type: :auth, reason_code: 0x00, properties: %{authentication_method: "TOY"}}
      assert {:close, :protocol_error, _} = Proto.handle_data(encode(5, auth), state)
      assert %{type: :disconnect, reason_code: 0x82} = sent()
    end

    test "a missing Authentication Method is a Protocol Error", ctx do
      state = auth_connected(ctx, "auth-nomethod")
      auth = %{type: :auth, reason_code: 0x19, properties: %{}}
      assert {:close, :protocol_error, _} = Proto.handle_data(encode(5, auth), state)
      assert %{type: :disconnect, reason_code: 0x82} = sent()
    end
  end

  describe "client PUBLISH carrying a Subscription Identifier (MQTT-3.3.4-6)" do
    test "is a Protocol Error", ctx do
      state = connected(ctx, "subid")
      packet = publish("t", "p", 0, nil, %{subscription_identifier: 5})
      assert {:close, :protocol_error, _} = Proto.handle_data(encode(5, packet), state)
      assert %{type: :disconnect, reason_code: 0x82} = sent()
      refute_received {:handle_publish, _, _}
    end
  end

  describe "outbound Packet Identifiers (MQTT-2.2.1-4)" do
    test "skip identifiers still in flight", ctx do
      state = connected(ctx, "pid") |> subscribed("out/#", 1)
      held = publish("out/x", "held", 1, 1)
      state = %{state | next_packet_id: 1, pending_qos1_tx: %{1 => held, 2 => held}}

      {:noreply, state} =
        Proto.handle_info({:send_publish, "out/t", "p", %{qos: 1, retain: false}}, state)

      assert %{type: :publish, packet_id: 3} = sent()
      assert Map.keys(state.pending_qos1_tx) |> Enum.sort() == [1, 2, 3]
    end
  end

  describe "application-supplied publish properties (MQTT-3.1.2-26, §3.3.4)" do
    test "Topic Alias and Subscription Identifier are stripped; ours is attached", ctx do
      state = connected(ctx, "props") |> subscribed("out/#", 0, %{subscription_identifier: 9})

      opts = %{
        qos: 0,
        retain: false,
        properties: %{topic_alias: 3, subscription_identifier: 77, user_properties: [{"k", "v"}]}
      }

      {:noreply, _} = Proto.handle_info({:send_publish, "out/t", "p", opts}, state)

      assert %{type: :publish, properties: props} = sent()
      refute Map.has_key?(props, :topic_alias)
      assert props.subscription_identifier == 9
      assert props.user_properties == [{"k", "v"}]
    end
  end

  describe "Message Expiry while queued behind Receive Maximum (MQTT-3.3.2-6)" do
    test "is aged on send and an expired message is dropped", ctx do
      state =
        connected(ctx, "expiry", 5, %{properties: %{receive_maximum: 1}})
        |> subscribed("out/#", 1)

      send_out = fn st, payload, props ->
        {:noreply, st} =
          Proto.handle_info(
            {:send_publish, "out/t", payload, %{qos: 1, retain: false, properties: props}},
            st
          )

        st
      end

      state = send_out.(state, "first", %{})
      assert %{type: :publish, payload: "first", packet_id: first_id} = sent()

      state = send_out.(state, "long", %{message_expiry_interval: 10})
      state = send_out.(state, "short", %{message_expiry_interval: 1})
      refute_received {:sent, _}
      assert :queue.len(state.outbound_queue) == 2

      # Pretend both have been waiting 2.5 s
      then = System.monotonic_time(:millisecond) - 2_500

      state = %{
        state
        | outbound_queue:
            :queue.from_list(
              for {t, p, o, _} <- :queue.to_list(state.outbound_queue), do: {t, p, o, then}
            )
      }

      # Window frees: "long" goes out with its expiry reduced by the wait
      state =
        feed(state, 5, %{type: :puback, packet_id: first_id, reason_code: 0, properties: %{}})

      assert %{type: :publish, payload: "long", packet_id: long_id, properties: props} = sent()
      assert props.message_expiry_interval == 8

      # Window frees again: "short" expired while queued — dropped, nothing sent
      state =
        feed(state, 5, %{type: :puback, packet_id: long_id, reason_code: 0, properties: %{}})

      refute_received {:sent, _}
      assert :queue.len(state.outbound_queue) == 0
    end
  end

  describe ":max_outbound_queue" do
    test "bounds the Receive Maximum queue; :infinity lifts the bound", ctx do
      state =
        connected(ctx, "cap", 5, %{properties: %{receive_maximum: 1}},
          transport_opts: %{max_outbound_queue: 1}
        )
        |> subscribed("out/#", 1)

      state =
        Enum.reduce(["a", "b", "c"], state, fn payload, st ->
          {:noreply, st} =
            Proto.handle_info({:send_publish, "out/t", payload, %{qos: 1, retain: false}}, st)

          st
        end)

      # "a" in flight, "b" queued, "c" dropped at the cap
      assert [%{payload: "a"}] = sent_all()
      assert :queue.len(state.outbound_queue) == 1

      unbounded = init(ctx, transport_opts: %{max_outbound_queue: :infinity})
      assert unbounded.max_outbound_queue == nil
    end
  end

  describe "SUBACK (§3.8.4, §3.9.3)" do
    test "reports min(requested, granted) and only SUBACK reason codes", ctx do
      state = connected(ctx, "suback", 5, %{}, grants: [2, 0x8E])

      _ =
        feed(
          state,
          5,
          subscribe(1, [%{topic: "a", qos: 0}, %{topic: "b", qos: 1}])
        )

      # Granted 2 for a QoS 0 request → 0; 0x8E is not a SUBACK code → 0x80
      assert %{type: :suback, acks: [{:ok, 0}, {:error, 0x80}]} = sent()
    end
  end

  describe "server DISCONNECT properties (MQTT-3.14.2-2)" do
    test "Session Expiry Interval is never sent by the broker", ctx do
      state = connected(ctx, "sei")
      props = %{session_expiry_interval: 5, reason_string: "bye"}
      {:stop, :normal, _} = Proto.handle_info({:kick, 0x80, props}, state)

      assert %{type: :disconnect, reason_code: 0x80, properties: sent_props} = sent()
      refute Map.has_key?(sent_props, :session_expiry_interval)
      assert sent_props.reason_string == "bye"
    end
  end

  describe "oversized packet during the enhanced-auth exchange (MQTT-3.14.0-1)" do
    test "fails the CONNECT with CONNACK 0x95 rather than a DISCONNECT", ctx do
      state = init(ctx, transport_opts: %{max_packet_size: 40})
      state = feed(state, 5, connect("a", 5, %{properties: %{authentication_method: "TOY"}}))
      assert %{type: :auth, reason_code: 0x18} = sent()

      big = %{
        type: :auth,
        reason_code: 0x18,
        properties: %{
          authentication_method: "TOY",
          authentication_data: String.duplicate("x", 100)
        }
      }

      assert {:close, :auth_failed, _} = Proto.handle_data(encode(5, big), state)
      assert %{type: :connack, reason_code: 0x95} = sent()
      refute_received {:sent, _}
    end
  end
end
