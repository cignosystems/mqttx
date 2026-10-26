defmodule MqttX.Transport.HandlerPathsTest do
  @moduledoc """
  Paths of the protocol handler that the other tests do not reach: a socket
  error on a connected client with a Will, `{:disconnect, ...}` returned
  from the subscribe, unsubscribe and publish callbacks, the PUBACK codes
  for each refusal reason, and a Topic Alias the client never mapped.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Transport.Handler, as: Proto

  # Records what it is told; refuses or disconnects on cue from the topic
  defmodule Recorder do
    use MqttX.Server

    def init(opts), do: %{agent: Keyword.fetch!(opts, :agent)}

    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    def handle_publish(topic, _payload, _opts, state) do
      topic = name(topic)
      record(state, {:publish, topic})

      case topic do
        "refuse/quota" -> {:error, :quota_exceeded, state}
        "refuse/topic" -> {:error, :topic_name_invalid, state}
        "refuse/format" -> {:error, :payload_format_invalid, state}
        "refuse/other" -> {:error, :something_else, state}
        "kick" -> {:disconnect, 0x98, state}
        "kick/props" -> {:disconnect, 0x98, %{reason_string: "no"}, state}
        _ -> {:ok, state}
      end
    end

    def handle_subscribe(topics, state) do
      case Enum.map(topics, &name(&1.topic)) do
        ["kick"] -> {:disconnect, 0x98, state}
        ["kick/props"] -> {:disconnect, 0x98, %{reason_string: "no"}, state}
        _ -> {:ok, Enum.map(topics, & &1.qos), state}
      end
    end

    def handle_unsubscribe(topics, state) do
      case Enum.map(topics, &name/1) do
        ["kick"] -> {:disconnect, 0x98, state}
        ["kick/props"] -> {:disconnect, 0x98, %{reason_string: "no"}, state}
        _ -> {:ok, state}
      end
    end

    def handle_disconnect(reason, state) do
      record(state, {:disconnect, reason})
      :ok
    end

    defp record(%{agent: agent}, event), do: Agent.update(agent, &[event | &1])

    # Topics arrive as segment lists from the wire and as strings from a Will
    defp name(topic) when is_list(topic), do: MqttX.Topic.flatten(topic)
    defp name(topic), do: topic
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    table = MqttX.Server.RetainedStore.new_table()
    test = self()
    send_fn = fn data -> send(test, {:sent, data}) end
    {:ok, state} = Proto.init(Recorder, [agent: agent], table, nil, send_fn)
    {:ok, agent: agent, state: state}
  end

  defp events(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  defp encode(packet), do: elem(Codec.encode(5, packet), 1)

  defp sent do
    assert_receive {:sent, data}
    {:ok, {packet, <<>>}} = Codec.decode(5, IO.iodata_to_binary(data))
    packet
  end

  # A connected v5 client, its CONNACK consumed
  defp connect(state, will \\ nil) do
    connect =
      encode(%{
        type: :connect,
        protocol_version: 5,
        client_id: "paths",
        username: nil,
        password: nil,
        will: will,
        clean_session: true,
        keep_alive: 60,
        properties: %{}
      })

    {:ok, state} = Proto.handle_data(connect, state)
    assert %{type: :connack, reason_code: 0} = sent()
    state
  end

  defp publish(topic, qos, packet_id, properties \\ %{}) do
    encode(%{
      type: :publish,
      topic: topic,
      payload: "x",
      qos: qos,
      retain: false,
      dup: false,
      packet_id: packet_id,
      properties: properties
    })
  end

  test "a socket error on a connected client publishes its Will and reports the error", ctx do
    will = %{topic: "w/t", payload: "bye", qos: 0, retain: false, properties: %{}}
    state = connect(ctx.state, will)

    assert {:shutdown, _state} = Proto.handle_error(:econnreset, state)
    assert [{:publish, "w/t"}, {:disconnect, {:error, :econnreset}}] = events(ctx.agent)
  end

  describe "{:disconnect, code, state} from a callback" do
    # The DISCONNECT the client gets, with the properties of a 4-tuple
    defp assert_kicked(ctx, result, props) do
      assert {:close, {:server_disconnect, 0x98}, _state} = result
      assert %{type: :disconnect, reason_code: 0x98, properties: ^props} = sent()
      assert {:disconnect, {:server_disconnect, 0x98}} in events(ctx.agent)
    end

    test "handle_subscribe", ctx do
      for {filter, props} <- [{"kick", %{}}, {"kick/props", %{reason_string: "no"}}] do
        state = connect(ctx.state)

        subscribe =
          encode(%{
            type: :subscribe,
            packet_id: 1,
            topics: [%{topic: filter, qos: 0}],
            properties: %{}
          })

        assert_kicked(ctx, Proto.handle_data(subscribe, state), props)
      end
    end

    test "handle_unsubscribe", ctx do
      for {filter, props} <- [{"kick", %{}}, {"kick/props", %{reason_string: "no"}}] do
        state = connect(ctx.state)

        unsubscribe =
          encode(%{type: :unsubscribe, packet_id: 2, topics: [filter], properties: %{}})

        assert_kicked(ctx, Proto.handle_data(unsubscribe, state), props)
      end
    end

    test "handle_publish at QoS 0", ctx do
      for {topic, props} <- [{"kick", %{}}, {"kick/props", %{reason_string: "no"}}] do
        state = connect(ctx.state)
        assert_kicked(ctx, Proto.handle_data(publish(topic, 0, nil), state), props)
      end
    end

    test "handle_publish at QoS 2, which runs at PUBREL", ctx do
      for {topic, props} <- [{"kick", %{}}, {"kick/props", %{reason_string: "no"}}] do
        state = connect(ctx.state)
        {:ok, state} = Proto.handle_data(publish(topic, 2, 5), state)
        assert %{type: :pubrec, packet_id: 5} = sent()
        pubrel = encode(%{type: :pubrel, packet_id: 5})
        assert_kicked(ctx, Proto.handle_data(pubrel, state), props)
      end
    end
  end

  test "a refused QoS 1 publish is acknowledged with the reason's code", ctx do
    state = connect(ctx.state)

    codes = [
      {"refuse/quota", 11, 0x97},
      {"refuse/topic", 12, 0x90},
      {"refuse/format", 13, 0x99},
      {"refuse/other", 14, 0x80}
    ]

    Enum.reduce(codes, state, fn {topic, id, code}, state ->
      {:ok, state} = Proto.handle_data(publish(topic, 1, id), state)
      assert %{type: :puback, packet_id: ^id, reason_code: ^code} = sent()
      state
    end)
  end

  test "a Topic Alias the client never mapped is a protocol error (§3.3.2.3.4)", ctx do
    state = connect(ctx.state)
    alias_only = publish("", 0, nil, %{topic_alias: 1})

    assert {:close, {:server_disconnect, 0x94}, _state} = Proto.handle_data(alias_only, state)
    assert %{type: :disconnect, reason_code: 0x94} = sent()
    refute {:publish, ""} in events(ctx.agent)
  end
end
