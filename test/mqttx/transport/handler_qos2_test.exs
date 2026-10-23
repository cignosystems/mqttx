defmodule MqttX.Transport.HandlerQos2Test do
  @moduledoc """
  QoS 2 paths in the broker handler not covered by the main handler suite: the
  broker as *sender* (PUBLISH → PUBREC → PUBREL → PUBCOMP, §4.3.3, with the
  `handle_puback/2` callback on completion), the §4.4 rule that nothing is
  re-sent on a live connection, and two inbound completions — a retained QoS 2
  message stored only at PUBREL, and a handler error at PUBREL still completing
  the flow.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Server.RetainedStore
  alias MqttX.Transport.Handler, as: Proto

  defmodule Publisher do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(_topic, "reject", _opts, state), do: {:error, :nope, state}

    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:handle_publish, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok

    @impl true
    def handle_info({:send_publish, topic, payload, opts}, state) do
      {:publish, topic, payload, opts, state}
    end

    @impl true
    def handle_puback(packet_id, state) do
      send(state.notify, {:handle_puback, packet_id})
      {:ok, state}
    end
  end

  setup do
    retained = RetainedStore.new_table()
    send_fn = fn data -> send(self(), {:sent, data}) end
    {:ok, retained: retained, send_fn: send_fn}
  end

  defp connect_subscriber(ctx, client_id, version \\ 5, connect_props \\ %{}, handler_opts \\ []) do
    {:ok, state} =
      Proto.init(Publisher, [notify: self()] ++ handler_opts, ctx.retained, nil, ctx.send_fn)

    state =
      feed(state, version, %{
        type: :connect,
        protocol_version: version,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 0,
        properties: connect_props
      })

    state =
      feed(state, version, %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "out/#", qos: 2}],
        properties: %{}
      })

    drain()
    state
  end

  defp feed(state, version, packet) do
    {:ok, data} = Codec.encode(version, packet)
    {:ok, state} = Proto.handle_data(data, state)
    state
  end

  defp publish_out(state, topic, payload, qos) do
    {:noreply, state} =
      Proto.handle_info({:send_publish, topic, payload, %{qos: qos, retain: false}}, state)

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

  describe "outbound QoS 2" do
    test "PUBLISH → PUBREC → PUBREL → PUBCOMP completes the flow and calls handle_puback/2",
         ctx do
      state = connect_subscriber(ctx, "q2-out")
      state = publish_out(state, "out/t", "p", 2)

      assert %{type: :publish, qos: 2, packet_id: id} = sent()
      assert %{phase: :pubrec_pending} = state.pending_qos2_tx[id]

      state = feed(state, 5, %{type: :pubrec, packet_id: id, reason_code: 0, properties: %{}})

      assert %{type: :pubrel, packet_id: ^id} = sent()
      assert %{phase: :pubrel_sent} = state.pending_qos2_tx[id]

      state = feed(state, 5, %{type: :pubcomp, packet_id: id, reason_code: 0, properties: %{}})

      assert state.pending_qos2_tx == %{}
      assert_received {:handle_puback, ^id}
    end

    test "a duplicate PUBREC after PUBREL was sent does not trigger a second PUBREL", ctx do
      state = connect_subscriber(ctx, "q2-dup-pubrec")
      state = publish_out(state, "out/t", "p", 2)
      %{packet_id: id} = sent()

      pubrec = %{type: :pubrec, packet_id: id, reason_code: 0, properties: %{}}
      state = feed(state, 5, pubrec)
      assert %{type: :pubrel} = sent()

      state = feed(state, 5, pubrec)
      refute_received {:sent, _}
      assert %{phase: :pubrel_sent} = state.pending_qos2_tx[id]
    end

    test "an error PUBREC aborts the flow without PUBREL and frees the window", ctx do
      # Receive Maximum 1: the second publish has to wait for the first slot
      state = connect_subscriber(ctx, "q2-error-pubrec", 5, %{receive_maximum: 1})
      state = publish_out(state, "out/first", "1", 2)
      state = publish_out(state, "out/second", "2", 2)

      assert %{type: :publish, topic: ["out", "first"], packet_id: id} = sent()
      refute_received {:sent, _}
      assert :queue.len(state.outbound_queue) == 1

      # 0x80 Unspecified error
      state = feed(state, 5, %{type: :pubrec, packet_id: id, reason_code: 0x80, properties: %{}})

      refute Map.has_key?(state.pending_qos2_tx, id)
      # The freed slot went to the queued publish — the only thing sent
      assert [%{type: :publish, topic: ["out", "second"]}] = sent_all()
      assert :queue.len(state.outbound_queue) == 0
    end

    test "a PUBREC for an unknown id is answered PUBREL 0x92 on v5 and ignored on v4", ctx do
      state = connect_subscriber(ctx, "q2-unknown-v5")
      _ = feed(state, 5, %{type: :pubrec, packet_id: 999, reason_code: 0, properties: %{}})
      assert %{type: :pubrel, packet_id: 999, reason_code: 0x92} = sent()

      state = connect_subscriber(ctx, "q2-unknown-v4", 4)
      _ = feed(state, 4, %{type: :pubrec, packet_id: 999})
      refute_received {:sent, _}
    end
  end

  describe "no retransmission on a live connection (§4.4)" do
    test "an unacknowledged outbound QoS 2 PUBLISH is held, not re-sent or dropped", ctx do
      # The pre-0.12 retry knobs, set so aggressively that a retry timer would
      # fire into this process (the handler's self()) within the test.
      state =
        connect_subscriber(ctx, "q2-no-retry", 5, %{},
          transport_opts: %{qos2_retry_interval: 20, qos2_max_retries: 0}
        )

      state = publish_out(state, "out/held", "h", 2)
      assert %{type: :publish, packet_id: id, dup: false} = sent()

      refute_receive :check_qos2_retry, 150
      refute_received {:sent, _}
      assert %{phase: :pubrec_pending} = state.pending_qos2_tx[id]

      # A late PUBREC still completes the flow normally
      state = feed(state, 5, %{type: :pubrec, packet_id: id, reason_code: 0, properties: %{}})
      assert %{type: :pubrel, packet_id: ^id} = sent()
      assert %{phase: :pubrel_sent} = state.pending_qos2_tx[id]
    end

    test "an inbound QoS 2 PUBLISH waiting for PUBREL is kept; PUBREC goes out again only for a DUP",
         ctx do
      state = connect_subscriber(ctx, "q2-rx-held")

      state = feed(state, 5, publish_in("held/q2", "v", 11, false))
      assert %{type: :pubrec, packet_id: 11} = sent()

      refute_receive :check_qos2_retry, 150
      refute_received {:sent, _}
      assert {%{payload: "v"}, _opts} = state.pending_qos2_rx[11]
      assert state.inflight_count == 1

      _ = feed(state, 5, %{publish_in("held/q2", "v", 11, false) | dup: true})
      assert %{type: :pubrec, packet_id: 11} = sent()
    end
  end

  describe "inbound QoS 2 completion" do
    defp publish_in(topic, payload, packet_id, retain) do
      %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: 2,
        retain: retain,
        dup: false,
        packet_id: packet_id,
        properties: %{}
      }
    end

    test "a retained QoS 2 PUBLISH is stored only when PUBREL completes it", ctx do
      state = connect_subscriber(ctx, "q2-retain-in")

      state = feed(state, 5, publish_in("ret/q2", "v", 9, true))
      assert %{type: :pubrec, packet_id: 9} = sent()
      # Not delivered to the handler, and not retained, until released
      refute_received {:handle_publish, _, _}
      assert RetainedStore.match(ctx.retained, "ret/q2") == []

      state = feed(state, 5, %{type: :pubrel, packet_id: 9, reason_code: 0, properties: %{}})
      assert %{type: :pubcomp, packet_id: 9} = sent()
      assert_received {:handle_publish, "ret/q2", "v"}

      assert [{"ret/q2", "v", 2, _ts, _expiry, _props}] =
               RetainedStore.match(ctx.retained, "ret/q2")

      assert state.pending_qos2_rx == %{}
    end

    test "a handler error at PUBREL still answers PUBCOMP and clears the entry", ctx do
      state = connect_subscriber(ctx, "q2-handler-error")

      state = feed(state, 5, publish_in("err/q2", "reject", 8, false))
      assert %{type: :pubrec, packet_id: 8} = sent()
      assert state.inflight_count == 1

      state = feed(state, 5, %{type: :pubrel, packet_id: 8, reason_code: 0, properties: %{}})

      assert %{type: :pubcomp, packet_id: 8, reason_code: 0} = sent()
      assert state.pending_qos2_rx == %{}
      assert state.inflight_count == 0
    end
  end
end
