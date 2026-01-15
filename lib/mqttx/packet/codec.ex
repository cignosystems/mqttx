defmodule MqttX.Packet.Codec do
  @moduledoc """
  High-performance MQTT packet encoder and decoder.

  Supports MQTT 3.1, 3.1.1, and 5.0 protocols with all 15 packet types.

  ## Encoding

      packet = %{type: :publish, topic: "test", payload: "hello", qos: 0, retain: false}
      {:ok, binary} = MqttX.Packet.Codec.encode(4, packet)

  ## Decoding

      {:ok, {packet, rest}} = MqttX.Packet.Codec.decode(4, binary)
  """

  import Bitwise

  alias MqttX.Packet.{Varint, Properties}
  alias MqttX.Topic

  # Packet type codes
  @connect 1
  @connack 2
  @publish 3
  @puback 4
  @pubrec 5
  @pubrel 6
  @pubcomp 7
  @subscribe 8
  @suback 9
  @unsubscribe 10
  @unsuback 11
  @pingreq 12
  @pingresp 13
  @disconnect 14
  @auth 15

  # Protocol names
  @protocol_name_3 "MQIsdp"
  @protocol_name "MQTT"

  # Maximum packet size
  @max_packet_size 268_435_455

  # ============================================================================
  # DECODE
  # ============================================================================

  @doc """
  Decode an MQTT packet from binary data.

  Returns `{:ok, {packet, rest}}` on success, `{:error, reason}` on failure,
  or `{:error, :incomplete}` if more data is needed.
  """
  @spec decode(integer(), binary()) ::
          {:ok, {map(), binary()}} | {:error, atom()}
  def decode(version, <<type::4, flags::4, rest::binary>>) do
    case decode_remaining_length(rest) do
      {:ok, len, payload_start} when byte_size(payload_start) >= len ->
        <<payload::binary-size(len), remaining::binary>> = payload_start
        case decode_packet(version, type, flags, payload) do
          {:ok, packet} -> {:ok, {packet, remaining}}
          {:error, _} = err -> err
        end

      {:ok, _len, _payload_start} ->
        {:error, :incomplete}

      :incomplete ->
        {:error, :incomplete}

      {:error, _} = err ->
        err
    end
  end

  def decode(_version, <<>>) do
    {:error, :incomplete}
  end

  def decode(_version, _) do
    {:error, :malformed_packet}
  end

  # Optimized remaining length decoder
  defp decode_remaining_length(<<0::1, len::7, rest::binary>>), do: {:ok, len, rest}
  defp decode_remaining_length(<<1::1, b1::7, 0::1, b2::7, rest::binary>>), do: {:ok, b1 + (b2 <<< 7), rest}
  defp decode_remaining_length(<<1::1, b1::7, 1::1, b2::7, 0::1, b3::7, rest::binary>>), do: {:ok, b1 + (b2 <<< 7) + (b3 <<< 14), rest}
  defp decode_remaining_length(<<1::1, b1::7, 1::1, b2::7, 1::1, b3::7, 0::1, b4::7, rest::binary>>), do: {:ok, b1 + (b2 <<< 7) + (b3 <<< 14) + (b4 <<< 21), rest}
  defp decode_remaining_length(<<1::1, _::7, 1::1, _::7, 1::1, _::7, 1::1, _::7, _::binary>>), do: {:error, :malformed_header}
  defp decode_remaining_length(_), do: :incomplete

  # CONNECT
  defp decode_packet(_version,
         @connect,
         0,
         <<proto_len::16-big, proto::binary-size(proto_len),
           protocol_level::8,
           user_flag::1, pass_flag::1, will_retain::1, will_qos::2, will_flag::1, clean::1, _reserved::1,
           keepalive::16-big,
           rest::binary>>) do

    case validate_protocol(proto, protocol_level) do
      {:ok, protocol_version} ->
        {:ok, props, rest2} = Properties.decode(protocol_version, rest)
        {client_id, rest3} = decode_utf8(rest2)
        {:ok, will_props, rest4} = if will_flag == 1, do: Properties.decode(protocol_version, rest3), else: {:ok, %{}, rest3}
        {will_topic, rest5} = decode_utf8_optional(rest4, will_flag)
        {will_payload, rest6} = decode_binary_optional(rest5, will_flag)
        {username, rest7} = decode_utf8_optional(rest6, user_flag)
        {password, <<>>} = decode_utf8_optional(rest7, pass_flag)

        will = if will_flag == 1 do
          %{
            topic: will_topic,
            payload: will_payload,
            qos: will_qos,
            retain: will_retain == 1,
            properties: will_props
          }
        else
          nil
        end

        {:ok, %{
          type: :connect,
          protocol_name: proto,
          protocol_version: protocol_version,
          client_id: client_id,
          clean_session: clean == 1,
          keep_alive: keepalive,
          properties: props,
          username: username,
          password: password,
          will: will
        }}

      {:error, _} = err ->
        err
    end
  end

  # CONNACK
  defp decode_packet(version, @connack, 0, <<_reserved::7, session_present::1, reason_code::8, rest::binary>>) do
    {:ok, props, <<>>} = Properties.decode(version, rest)
    {:ok, %{
      type: :connack,
      session_present: session_present == 1,
      reason_code: reason_code,
      properties: props
    }}
  end

  # PUBLISH
  defp decode_packet(version, @publish, flags, <<topic_len::16-big, topic::binary-size(topic_len), rest::binary>>) do
    dup = (flags &&& 0b1000) == 0b1000
    qos = (flags &&& 0b0110) >>> 1
    retain = (flags &&& 0b0001) == 0b0001

    {packet_id, rest2} = case qos do
      0 -> {nil, rest}
      _ ->
        <<pid::16-big, r::binary>> = rest
        {pid, r}
    end

    {:ok, props, payload} = Properties.decode(version, rest2)

    case Topic.validate_publish(topic) do
      {:ok, normalized_topic} ->
        {:ok, %{
          type: :publish,
          dup: dup,
          qos: qos,
          retain: retain,
          topic: normalized_topic,
          packet_id: packet_id,
          properties: props,
          payload: payload
        }}
      {:error, _} ->
        {:error, :invalid_topic}
    end
  end

  # PUBACK, PUBREC, PUBCOMP
  defp decode_packet(version, type, 0, <<packet_id::16-big, rest::binary>>)
       when type in [@puback, @pubrec, @pubcomp] do
    {reason_code, props} = decode_ack_payload(version, rest)
    {:ok, %{
      type: type_to_atom(type),
      packet_id: packet_id,
      reason_code: reason_code,
      properties: props
    }}
  end

  # PUBREL (has fixed flags 0010)
  defp decode_packet(version, @pubrel, 2, <<packet_id::16-big, rest::binary>>) do
    {reason_code, props} = decode_ack_payload(version, rest)
    {:ok, %{
      type: :pubrel,
      packet_id: packet_id,
      reason_code: reason_code,
      properties: props
    }}
  end

  # SUBSCRIBE
  defp decode_packet(version, @subscribe, 2, <<packet_id::16-big, rest::binary>>) do
    {:ok, props, topics_bin} = Properties.decode(version, rest)
    case decode_subscribe_topics(topics_bin, []) do
      {:ok, topics} ->
        {:ok, %{
          type: :subscribe,
          packet_id: packet_id,
          properties: props,
          topics: topics
        }}
      {:error, _} = err ->
        err
    end
  end

  # SUBACK
  defp decode_packet(version, @suback, 0, <<packet_id::16-big, rest::binary>>) do
    {:ok, props, acks_bin} = Properties.decode(version, rest)
    acks = decode_suback_acks(acks_bin, [])
    {:ok, %{
      type: :suback,
      packet_id: packet_id,
      properties: props,
      acks: acks
    }}
  end

  # UNSUBSCRIBE
  defp decode_packet(version, @unsubscribe, 2, <<packet_id::16-big, rest::binary>>) do
    {:ok, props, topics_bin} = Properties.decode(version, rest)
    case decode_unsubscribe_topics(topics_bin, []) do
      {:ok, topics} ->
        {:ok, %{
          type: :unsubscribe,
          packet_id: packet_id,
          properties: props,
          topics: topics
        }}
      {:error, _} = err ->
        err
    end
  end

  # UNSUBACK
  defp decode_packet(version, @unsuback, 0, <<packet_id::16-big, rest::binary>>) do
    {:ok, props, acks_bin} = Properties.decode(version, rest)
    acks = decode_unsuback_acks(acks_bin, [])
    {:ok, %{
      type: :unsuback,
      packet_id: packet_id,
      properties: props,
      acks: acks
    }}
  end

  # PINGREQ
  defp decode_packet(_version, @pingreq, 0, <<>>) do
    {:ok, %{type: :pingreq}}
  end

  # PINGRESP
  defp decode_packet(_version, @pingresp, 0, <<>>) do
    {:ok, %{type: :pingresp}}
  end

  # DISCONNECT
  defp decode_packet(_version, @disconnect, 0, <<>>) do
    {:ok, %{type: :disconnect, reason_code: 0, properties: %{}}}
  end

  defp decode_packet(version, @disconnect, 0, <<reason_code::8, rest::binary>>) do
    {:ok, props, <<>>} = Properties.decode(version, rest)
    {:ok, %{
      type: :disconnect,
      reason_code: reason_code,
      properties: props
    }}
  end

  # AUTH (MQTT 5.0 only)
  defp decode_packet(5, @auth, 0, <<>>) do
    {:ok, %{type: :auth, reason_code: 0, properties: %{}}}
  end

  defp decode_packet(5, @auth, 0, <<reason_code::8, rest::binary>>) do
    {:ok, props, <<>>} = Properties.decode(5, rest)
    {:ok, %{
      type: :auth,
      reason_code: reason_code,
      properties: props
    }}
  end

  # Invalid packet
  defp decode_packet(_version, _type, _flags, _payload) do
    {:error, :invalid_packet}
  end

  # ============================================================================
  # ENCODE
  # ============================================================================

  @doc """
  Encode an MQTT packet to binary.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure.
  """
  @spec encode(integer(), map()) :: {:ok, binary()} | {:error, atom()}
  def encode(version, packet) do
    case encode_packet(version, packet) do
      {:ok, {header, variable}} ->
        var_bin = IO.iodata_to_binary(variable)
        size = byte_size(var_bin)
        if size <= @max_packet_size do
          {:ok, <<header::binary, (Varint.encode(size))::binary, var_bin::binary>>}
        else
          {:error, :packet_too_large}
        end
      {:error, _} = err ->
        err
    end
  end

  @doc """
  Encode an MQTT packet to iodata (more efficient, avoids binary copy).
  """
  @spec encode_iodata(integer(), map()) :: {:ok, iodata()} | {:error, atom()}
  def encode_iodata(version, packet) do
    case encode_packet(version, packet) do
      {:ok, {header, variable}} ->
        var_len = IO.iodata_length(variable)
        if var_len <= @max_packet_size do
          {:ok, [header, Varint.encode(var_len), variable]}
        else
          {:error, :packet_too_large}
        end
      {:error, _} = err ->
        err
    end
  end

  # CONNECT
  defp encode_packet(version, %{type: :connect} = msg) do
    will_flag = if msg[:will], do: 1, else: 0
    will_qos = if msg[:will], do: Map.get(msg.will, :qos, 0), else: 0
    will_retain = if msg[:will] && Map.get(msg.will, :retain, false), do: 1, else: 0
    keepalive = Map.get(msg, :keep_alive, 0)
    clean = if Map.get(msg, :clean_session, true), do: 1, else: 0
    username_flag = if msg[:username], do: 1, else: 0
    password_flag = if msg[:password], do: 1, else: 0

    proto_name = protocol_name(version)

    variable = [
      encode_utf8(proto_name),
      <<version::8,
        username_flag::1, password_flag::1, will_retain::1, will_qos::2, will_flag::1, clean::1, 0::1,
        keepalive::16-big>>,
      Properties.encode(version, Map.get(msg, :properties, %{})),
      encode_utf8(Map.get(msg, :client_id, "")),
      encode_will(version, msg[:will]),
      encode_optional_utf8(msg[:username]),
      encode_optional_utf8(msg[:password])
    ]

    {:ok, {<<@connect::4, 0::4>>, variable}}
  end

  # CONNACK
  defp encode_packet(version, %{type: :connack} = msg) do
    session_present = if Map.get(msg, :session_present, false), do: 1, else: 0
    reason_code = Map.get(msg, :reason_code, 0)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))

    variable = [<<0::7, session_present::1, reason_code::8>>, props]
    {:ok, {<<@connack::4, 0::4>>, variable}}
  end

  # PUBLISH
  defp encode_packet(version, %{type: :publish} = msg) do
    qos = Map.get(msg, :qos, 0)
    dup = if Map.get(msg, :dup, false), do: 1, else: 0
    retain = if Map.get(msg, :retain, false), do: 1, else: 0

    topic = case msg.topic do
      t when is_list(t) -> Topic.flatten(t)
      t when is_binary(t) -> t
    end

    flags = (dup <<< 3) ||| (qos <<< 1) ||| retain

    packet_id_bin = case qos do
      0 -> <<>>
      _ -> <<Map.get(msg, :packet_id, 0)::16-big>>
    end

    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    payload = Map.get(msg, :payload, <<>>)

    variable = [encode_utf8(topic), packet_id_bin, props, payload]
    {:ok, {<<@publish::4, flags::4>>, variable}}
  end

  # PUBACK, PUBREC, PUBCOMP
  defp encode_packet(version, %{type: type} = msg) when type in [:puback, :pubrec, :pubcomp] do
    type_code = atom_to_type(type)
    packet_id = Map.get(msg, :packet_id, 0)
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = encode_ack_response(version, packet_id, reason_code, props)
    {:ok, {<<type_code::4, 0::4>>, variable}}
  end

  # PUBREL
  defp encode_packet(version, %{type: :pubrel} = msg) do
    packet_id = Map.get(msg, :packet_id, 0)
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = encode_ack_response(version, packet_id, reason_code, props)
    {:ok, {<<@pubrel::4, 2::4>>, variable}}
  end

  # SUBSCRIBE
  defp encode_packet(version, %{type: :subscribe} = msg) do
    packet_id = Map.get(msg, :packet_id, 0)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    topics = encode_subscribe_topics(Map.get(msg, :topics, []))

    variable = [<<packet_id::16-big>>, props, topics]
    {:ok, {<<@subscribe::4, 2::4>>, variable}}
  end

  # SUBACK
  defp encode_packet(version, %{type: :suback} = msg) do
    packet_id = Map.get(msg, :packet_id, 0)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    acks = encode_suback_acks(Map.get(msg, :acks, []))

    variable = [<<packet_id::16-big>>, props, acks]
    {:ok, {<<@suback::4, 0::4>>, variable}}
  end

  # UNSUBSCRIBE
  defp encode_packet(version, %{type: :unsubscribe} = msg) do
    packet_id = Map.get(msg, :packet_id, 0)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    topics = encode_unsubscribe_topics(Map.get(msg, :topics, []))

    variable = [<<packet_id::16-big>>, props, topics]
    {:ok, {<<@unsubscribe::4, 2::4>>, variable}}
  end

  # UNSUBACK
  defp encode_packet(version, %{type: :unsuback} = msg) do
    packet_id = Map.get(msg, :packet_id, 0)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    acks = encode_unsuback_acks(Map.get(msg, :acks, []))

    variable = [<<packet_id::16-big>>, props, acks]
    {:ok, {<<@unsuback::4, 0::4>>, variable}}
  end

  # PINGREQ
  defp encode_packet(_version, %{type: :pingreq}) do
    {:ok, {<<@pingreq::4, 0::4>>, <<>>}}
  end

  # PINGRESP
  defp encode_packet(_version, %{type: :pingresp}) do
    {:ok, {<<@pingresp::4, 0::4>>, <<>>}}
  end

  # DISCONNECT
  defp encode_packet(version, %{type: :disconnect} = msg) do
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = if reason_code == 0 and map_size(props) == 0 do
      <<>>
    else
      [<<reason_code::8>>, Properties.encode(version, props)]
    end

    {:ok, {<<@disconnect::4, 0::4>>, variable}}
  end

  # AUTH (MQTT 5.0 only)
  defp encode_packet(5, %{type: :auth} = msg) do
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = if reason_code == 0 and map_size(props) == 0 do
      <<>>
    else
      [<<reason_code::8>>, Properties.encode(5, props)]
    end

    {:ok, {<<@auth::4, 0::4>>, variable}}
  end

  defp encode_packet(_version, _packet) do
    {:error, :unsupported_packet}
  end

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  defp validate_protocol(@protocol_name_3, 3), do: {:ok, 3}
  defp validate_protocol(@protocol_name, 4), do: {:ok, 4}
  defp validate_protocol(@protocol_name, 5), do: {:ok, 5}
  # Mosquitto bridge variants
  defp validate_protocol(@protocol_name_3, 0x83), do: {:ok, 3}
  defp validate_protocol(@protocol_name, 0x84), do: {:ok, 4}
  defp validate_protocol(@protocol_name, 0x85), do: {:ok, 5}
  defp validate_protocol(_, _), do: {:error, :unknown_protocol}

  defp protocol_name(3), do: @protocol_name_3
  defp protocol_name(_), do: @protocol_name

  defp type_to_atom(@connect), do: :connect
  defp type_to_atom(@connack), do: :connack
  defp type_to_atom(@publish), do: :publish
  defp type_to_atom(@puback), do: :puback
  defp type_to_atom(@pubrec), do: :pubrec
  defp type_to_atom(@pubrel), do: :pubrel
  defp type_to_atom(@pubcomp), do: :pubcomp
  defp type_to_atom(@subscribe), do: :subscribe
  defp type_to_atom(@suback), do: :suback
  defp type_to_atom(@unsubscribe), do: :unsubscribe
  defp type_to_atom(@unsuback), do: :unsuback
  defp type_to_atom(@pingreq), do: :pingreq
  defp type_to_atom(@pingresp), do: :pingresp
  defp type_to_atom(@disconnect), do: :disconnect
  defp type_to_atom(@auth), do: :auth

  defp atom_to_type(:connect), do: @connect
  defp atom_to_type(:connack), do: @connack
  defp atom_to_type(:publish), do: @publish
  defp atom_to_type(:puback), do: @puback
  defp atom_to_type(:pubrec), do: @pubrec
  defp atom_to_type(:pubrel), do: @pubrel
  defp atom_to_type(:pubcomp), do: @pubcomp
  defp atom_to_type(:subscribe), do: @subscribe
  defp atom_to_type(:suback), do: @suback
  defp atom_to_type(:unsubscribe), do: @unsubscribe
  defp atom_to_type(:unsuback), do: @unsuback
  defp atom_to_type(:pingreq), do: @pingreq
  defp atom_to_type(:pingresp), do: @pingresp
  defp atom_to_type(:disconnect), do: @disconnect
  defp atom_to_type(:auth), do: @auth

  # UTF-8 string encoding/decoding
  defp encode_utf8(str) when is_binary(str) do
    <<byte_size(str)::16-big, str::binary>>
  end

  defp encode_optional_utf8(nil), do: <<>>
  defp encode_optional_utf8(str), do: encode_utf8(str)

  defp decode_utf8(<<len::16-big, str::binary-size(len), rest::binary>>) do
    {str, rest}
  end

  defp decode_utf8_optional(data, 0), do: {nil, data}
  defp decode_utf8_optional(data, 1), do: decode_utf8(data)

  defp decode_binary_optional(data, 0), do: {nil, data}
  defp decode_binary_optional(<<len::16-big, bin::binary-size(len), rest::binary>>, 1), do: {bin, rest}

  # Will message encoding
  defp encode_will(_version, nil), do: <<>>
  defp encode_will(version, will) do
    topic = case will.topic do
      t when is_list(t) -> Topic.flatten(t)
      t when is_binary(t) -> t
    end
    [
      Properties.encode(version, Map.get(will, :properties, %{})),
      encode_utf8(topic),
      encode_utf8(Map.get(will, :payload, <<>>))
    ]
  end

  # ACK payload handling (for MQTT 5.0)
  defp decode_ack_payload(5, <<>>) do
    {0, %{}}
  end

  defp decode_ack_payload(5, <<reason_code::8, rest::binary>>) do
    {:ok, props, <<>>} = Properties.decode(5, rest)
    {reason_code, props}
  end

  defp decode_ack_payload(_version, <<>>) do
    {0, %{}}
  end

  defp encode_ack_response(5, packet_id, reason_code, props) when reason_code == 0 and map_size(props) == 0 do
    [<<packet_id::16-big>>]
  end

  defp encode_ack_response(5, packet_id, reason_code, props) do
    [<<packet_id::16-big, reason_code::8>>, Properties.encode(5, props)]
  end

  defp encode_ack_response(_version, packet_id, _reason_code, _props) do
    [<<packet_id::16-big>>]
  end

  # Subscribe topics
  defp decode_subscribe_topics(<<>>, topics) do
    {:ok, Enum.reverse(topics)}
  end

  defp decode_subscribe_topics(<<len::16-big, name::binary-size(len), opts::8, rest::binary>>, topics) do
    <<_reserved::2, rh::2, rap::1, nl::1, qos::2>> = <<opts::8>>

    case Topic.validate(name) do
      {:ok, normalized} ->
        topic = %{
          topic: normalized,
          qos: qos,
          no_local: nl == 1,
          retain_as_published: rap == 1,
          retain_handling: rh
        }
        decode_subscribe_topics(rest, [topic | topics])
      {:error, _} = err ->
        err
    end
  end

  defp encode_subscribe_topics(topics) do
    Enum.map(topics, fn topic ->
      name = case topic do
        %{topic: t} when is_list(t) -> Topic.flatten(t)
        %{topic: t} when is_binary(t) -> t
        t when is_binary(t) -> t
        t when is_list(t) -> Topic.flatten(t)
      end

      qos = Map.get(topic, :qos, 0)
      nl = if Map.get(topic, :no_local, false), do: 1, else: 0
      rap = if Map.get(topic, :retain_as_published, false), do: 1, else: 0
      rh = Map.get(topic, :retain_handling, 0)

      [encode_utf8(name), <<0::2, rh::2, rap::1, nl::1, qos::2>>]
    end)
  end

  # Unsubscribe topics
  defp decode_unsubscribe_topics(<<>>, topics) do
    {:ok, Enum.reverse(topics)}
  end

  defp decode_unsubscribe_topics(<<len::16-big, name::binary-size(len), rest::binary>>, topics) do
    case Topic.validate(name) do
      {:ok, normalized} -> decode_unsubscribe_topics(rest, [normalized | topics])
      {:error, _} = err -> err
    end
  end

  defp encode_unsubscribe_topics(topics) do
    Enum.map(topics, fn topic ->
      name = case topic do
        t when is_list(t) -> Topic.flatten(t)
        t when is_binary(t) -> t
      end
      encode_utf8(name)
    end)
  end

  # SUBACK acks
  defp decode_suback_acks(<<>>, acks) do
    Enum.reverse(acks)
  end

  defp decode_suback_acks(<<0::6, qos::2, rest::binary>>, acks) do
    decode_suback_acks(rest, [{:ok, qos} | acks])
  end

  defp decode_suback_acks(<<reason::8, rest::binary>>, acks) when reason >= 0x80 do
    decode_suback_acks(rest, [{:error, reason} | acks])
  end

  defp encode_suback_acks(acks) do
    Enum.map(acks, fn
      {:ok, qos} when qos in [0, 1, 2] -> <<0::6, qos::2>>
      {:error, reason} when reason >= 0x80 -> <<reason::8>>
    end)
  end

  # UNSUBACK acks
  defp decode_unsuback_acks(<<>>, acks) do
    Enum.reverse(acks)
  end

  defp decode_unsuback_acks(<<0, rest::binary>>, acks) do
    decode_unsuback_acks(rest, [{:ok, :found} | acks])
  end

  defp decode_unsuback_acks(<<17, rest::binary>>, acks) do
    decode_unsuback_acks(rest, [{:ok, :notfound} | acks])
  end

  defp decode_unsuback_acks(<<reason::8, rest::binary>>, acks) when reason >= 0x80 do
    decode_unsuback_acks(rest, [{:error, reason} | acks])
  end

  defp encode_unsuback_acks(acks) do
    Enum.map(acks, fn
      {:ok, :found} -> <<0>>
      {:ok, :notfound} -> <<17>>
      {:error, reason} when reason >= 0x80 -> <<reason::8>>
    end)
  end
end
