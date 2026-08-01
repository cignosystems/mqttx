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
        <<payload::binary-size(^len), remaining::binary>> = payload_start

        case decode_packet(version, type, flags, payload) do
          {:ok, packet} ->
            {:ok, {packet, remaining}}

          {:error, :incomplete} ->
            # The payload slice is already complete per the declared remaining
            # length, so "ran out of bytes" inside it means the packet is
            # malformed, not that more data should be awaited (§4.13).
            {:error, :malformed_packet}

          {:error, _} = err ->
            err

          _other ->
            # A `with` clause leaked an unmatched value (e.g. properties with
            # trailing bytes). Never let it escape as a raise.
            {:error, :malformed_packet}
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

  @doc """
  Total on-the-wire size a buffered packet declares in its fixed header,
  without decoding the body.

  Returns `{:ok, total_bytes}` (fixed header + remaining length) once enough
  of the header has arrived, `:incomplete` if the header itself is still
  partial, or `{:error, :malformed_header}`. Lets transports reject oversized
  packets (§3.1.2.11.4) *before* buffering up to the declared size.
  """
  @spec declared_length(binary()) ::
          {:ok, non_neg_integer()} | :incomplete | {:error, :malformed_header}
  def declared_length(<<_type::4, _flags::4, rest::binary>>) do
    case decode_remaining_length(rest) do
      {:ok, len, payload_start} ->
        varint_size = byte_size(rest) - byte_size(payload_start)
        {:ok, 1 + varint_size + len}

      :incomplete ->
        :incomplete

      {:error, _} ->
        {:error, :malformed_header}
    end
  end

  def declared_length(_), do: :incomplete

  # Optimized remaining length decoder
  defp decode_remaining_length(<<0::1, len::7, rest::binary>>), do: {:ok, len, rest}

  defp decode_remaining_length(<<1::1, b1::7, 0::1, b2::7, rest::binary>>),
    do: {:ok, b1 + (b2 <<< 7), rest}

  defp decode_remaining_length(<<1::1, b1::7, 1::1, b2::7, 0::1, b3::7, rest::binary>>),
    do: {:ok, b1 + (b2 <<< 7) + (b3 <<< 14), rest}

  defp decode_remaining_length(
         <<1::1, b1::7, 1::1, b2::7, 1::1, b3::7, 0::1, b4::7, rest::binary>>
       ),
       do: {:ok, b1 + (b2 <<< 7) + (b3 <<< 14) + (b4 <<< 21), rest}

  defp decode_remaining_length(<<1::1, _::7, 1::1, _::7, 1::1, _::7, 1::1, _::7, _::binary>>),
    do: {:error, :malformed_header}

  defp decode_remaining_length(_), do: :incomplete

  # CONNECT
  defp decode_packet(
         _version,
         @connect,
         0,
         <<proto_len::16-big, proto::binary-size(proto_len), protocol_level::8, user_flag::1,
           pass_flag::1, will_retain::1, will_qos::2, will_flag::1, clean::1, reserved::1,
           keepalive::16-big, rest::binary>>
       ) do
    with :ok <- validate_connect_flags(reserved, will_flag, will_qos, will_retain),
         {:ok, protocol_version} <- validate_protocol(proto, protocol_level),
         :ok <- validate_user_pass_flags(protocol_version, user_flag, pass_flag),
         {:ok, props, rest2} <- Properties.decode(protocol_version, rest),
         {:ok, client_id, rest3} <- decode_utf8_safe(rest2),
         {:ok, will_props, rest4} <-
           if(will_flag == 1,
             do: Properties.decode(protocol_version, rest3),
             else: {:ok, %{}, rest3}
           ),
         {:ok, will_topic, rest5} <- decode_utf8_optional_safe(rest4, will_flag),
         {:ok, will_payload, rest6} <- decode_binary_optional_safe(rest5, will_flag),
         {:ok, username, rest7} <- decode_utf8_optional_safe(rest6, user_flag),
         {:ok, password, <<>>} <- decode_binary_optional_safe(rest7, pass_flag) do
      will =
        if will_flag == 1 do
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

      {:ok,
       %{
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
    else
      {:ok, _, _} -> {:error, :malformed_packet}
      {:error, _} = err -> err
    end
  end

  defp decode_packet(_version, @connect, _flags, _payload) do
    # CONNECT fixed-header flags MUST be 0 (§3.1.1)
    {:error, :malformed_packet}
  end

  # CONNACK
  defp decode_packet(
         version,
         @connack,
         0,
         <<_reserved::7, session_present::1, reason_code::8, rest::binary>>
       ) do
    with {:ok, props, <<>>} <- Properties.decode(version, rest) do
      {:ok,
       %{
         type: :connack,
         session_present: session_present == 1,
         reason_code: reason_code,
         properties: props
       }}
    end
  end

  # PUBLISH — §3.3.1.2 forbids QoS=3; §3.3.1.1 forbids DUP=1 with QoS=0
  defp decode_packet(_version, @publish, flags, _payload)
       when (flags &&& 0b0110) == 0b0110
       when (flags &&& 0b1110) == 0b1000 do
    {:error, :malformed_packet}
  end

  defp decode_packet(
         version,
         @publish,
         flags,
         <<topic_len::16-big, topic::binary-size(topic_len), rest::binary>>
       ) do
    dup = (flags &&& 0b1000) == 0b1000
    qos = (flags &&& 0b0110) >>> 1
    retain = (flags &&& 0b0001) == 0b0001

    with {:ok, packet_id, rest2} <- decode_publish_packet_id(qos, rest),
         {:ok, props, payload} <- Properties.decode(version, rest2),
         {:ok, normalized_topic} <- validate_publish_topic(topic, props) do
      {:ok,
       %{
         type: :publish,
         dup: dup,
         qos: qos,
         retain: retain,
         topic: normalized_topic,
         packet_id: packet_id,
         properties: props,
         payload: payload
       }}
    end
  end

  # PUBACK, PUBREC, PUBCOMP
  defp decode_packet(version, type, 0, <<packet_id::16-big, rest::binary>>)
       when type in [@puback, @pubrec, @pubcomp] do
    with {:ok, reason_code, props} <- decode_ack_payload(version, rest) do
      {:ok,
       %{
         type: type_to_atom(type),
         packet_id: packet_id,
         reason_code: reason_code,
         properties: props
       }}
    end
  end

  # PUBREL (has fixed flags 0010)
  defp decode_packet(version, @pubrel, 2, <<packet_id::16-big, rest::binary>>) do
    with {:ok, reason_code, props} <- decode_ack_payload(version, rest) do
      {:ok,
       %{
         type: :pubrel,
         packet_id: packet_id,
         reason_code: reason_code,
         properties: props
       }}
    end
  end

  # SUBSCRIBE — payload MUST contain at least one topic filter (§3.8.3)
  defp decode_packet(version, @subscribe, 2, <<packet_id::16-big, rest::binary>>) do
    with {:ok, props, topics_bin} <- Properties.decode(version, rest),
         {:ok, topics} <- decode_subscribe_topics(version, topics_bin, []),
         :ok <- ensure_nonempty_topics(topics) do
      {:ok,
       %{
         type: :subscribe,
         packet_id: packet_id,
         properties: props,
         topics: topics
       }}
    end
  end

  # SUBACK
  defp decode_packet(version, @suback, 0, <<packet_id::16-big, rest::binary>>) do
    with {:ok, props, acks_bin} <- Properties.decode(version, rest),
         {:ok, acks} <- decode_suback_acks(acks_bin, []) do
      {:ok,
       %{
         type: :suback,
         packet_id: packet_id,
         properties: props,
         acks: acks
       }}
    end
  end

  # UNSUBSCRIBE — payload MUST contain at least one topic filter (§3.10.3)
  defp decode_packet(version, @unsubscribe, 2, <<packet_id::16-big, rest::binary>>) do
    with {:ok, props, topics_bin} <- Properties.decode(version, rest),
         {:ok, topics} <- decode_unsubscribe_topics(topics_bin, []),
         :ok <- ensure_nonempty_topics(topics) do
      {:ok,
       %{
         type: :unsubscribe,
         packet_id: packet_id,
         properties: props,
         topics: topics
       }}
    end
  end

  # UNSUBACK
  defp decode_packet(version, @unsuback, 0, <<packet_id::16-big, rest::binary>>) do
    with {:ok, props, acks_bin} <- Properties.decode(version, rest),
         {:ok, acks} <- decode_unsuback_acks(acks_bin, []),
         # §3.11.3: a v5 UNSUBACK must carry ≥1 reason code (v3.1.1 has none)
         :ok <- if(version == 5 and acks == [], do: {:error, :malformed_packet}, else: :ok) do
      {:ok,
       %{
         type: :unsuback,
         packet_id: packet_id,
         properties: props,
         acks: acks
       }}
    end
  end

  # PINGREQ
  defp decode_packet(_version, @pingreq, 0, <<>>) do
    {:ok, %{type: :pingreq}}
  end

  # PINGRESP
  defp decode_packet(_version, @pingresp, 0, <<>>) do
    {:ok, %{type: :pingresp}}
  end

  # DISCONNECT — §3.14.2.2.1: 1-byte form (reason code only) is valid
  defp decode_packet(_version, @disconnect, 0, <<>>) do
    {:ok, %{type: :disconnect, reason_code: 0, properties: %{}}}
  end

  defp decode_packet(_version, @disconnect, 0, <<reason_code::8>>) do
    {:ok, %{type: :disconnect, reason_code: reason_code, properties: %{}}}
  end

  defp decode_packet(version, @disconnect, 0, <<reason_code::8, rest::binary>>) do
    with {:ok, props, <<>>} <- Properties.decode(version, rest) do
      {:ok,
       %{
         type: :disconnect,
         reason_code: reason_code,
         properties: props
       }}
    end
  end

  # AUTH (MQTT 5.0 only) — §3.15.2.2.1: 1-byte form is valid
  defp decode_packet(5, @auth, 0, <<>>) do
    {:ok, %{type: :auth, reason_code: 0, properties: %{}}}
  end

  defp decode_packet(5, @auth, 0, <<reason_code::8>>) do
    {:ok, %{type: :auth, reason_code: reason_code, properties: %{}}}
  end

  defp decode_packet(5, @auth, 0, <<reason_code::8, rest::binary>>) do
    with {:ok, props, <<>>} <- Properties.decode(5, rest) do
      {:ok,
       %{
         type: :auth,
         reason_code: reason_code,
         properties: props
       }}
    end
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
          {:ok, <<header::binary, Varint.encode(size)::binary, var_bin::binary>>}
        else
          {:error, :packet_too_large}
        end

      {:error, _} = err ->
        err
    end
  catch
    thrown -> encode_throw_to_error(thrown)
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
  catch
    thrown -> encode_throw_to_error(thrown)
  end

  # Shared mapping for the throw-based validation in encode_packet/2 and its
  # helpers. Anything not thrown by this module is re-thrown untouched.
  defp encode_throw_to_error(:mqttx_string_too_long), do: {:error, :string_too_long}
  defp encode_throw_to_error(:mqttx_invalid_utf8), do: {:error, :invalid_utf8}
  defp encode_throw_to_error(:mqttx_missing_packet_id), do: {:error, :missing_packet_id}
  defp encode_throw_to_error(:mqttx_invalid_qos), do: {:error, :invalid_qos}
  defp encode_throw_to_error(:mqttx_invalid_topic), do: {:error, :invalid_topic}
  defp encode_throw_to_error(:mqttx_empty_topic_list), do: {:error, :empty_topic_list}
  defp encode_throw_to_error(:mqttx_value_out_of_range), do: {:error, :value_out_of_range}

  defp encode_throw_to_error({:mqttx_invalid_property, name}),
    do: {:error, {:invalid_property, name}}

  defp encode_throw_to_error(other), do: throw(other)

  # CONNECT
  defp encode_packet(version, %{type: :connect} = msg) do
    will_flag = if msg[:will], do: 1, else: 0
    will_qos = if msg[:will], do: Map.get(msg.will, :qos, 0), else: 0
    will_retain = if msg[:will] && Map.get(msg.will, :retain, false), do: 1, else: 0
    keepalive = Map.get(msg, :keep_alive, 0)

    unless is_integer(keepalive) and keepalive in 0..0xFFFF do
      throw(:mqttx_value_out_of_range)
    end

    clean = if Map.get(msg, :clean_session, true), do: 1, else: 0
    username_flag = if msg[:username], do: 1, else: 0
    password_flag = if msg[:password], do: 1, else: 0

    proto_name = protocol_name(version)

    variable = [
      encode_utf8(proto_name),
      <<version::8, username_flag::1, password_flag::1, will_retain::1, will_qos::2, will_flag::1,
        clean::1, 0::1, keepalive::16-big>>,
      Properties.encode(version, Map.get(msg, :properties, %{})),
      encode_utf8(Map.get(msg, :client_id, "")),
      encode_will(version, msg[:will]),
      encode_optional_utf8(msg[:username]),
      # §3.1.3.6: the Password is BINARY data, not a UTF-8 string
      encode_optional_binary(msg[:password])
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
    if qos not in 0..2, do: throw(:mqttx_invalid_qos)

    dup = if Map.get(msg, :dup, false), do: 1, else: 0
    retain = if Map.get(msg, :retain, false), do: 1, else: 0

    topic =
      case msg.topic do
        t when is_list(t) -> Topic.flatten(t)
        t when is_binary(t) -> t
      end

    # Never emit a PUBLISH the receiver must reject: wildcards (or an empty
    # topic without a topic alias) are invalid in PUBLISH (§3.3.2.1).
    has_alias = is_integer(get_in(msg, [:properties, :topic_alias]))

    unless topic == "" and has_alias do
      case Topic.validate_publish(topic) do
        {:ok, _} -> :ok
        {:error, _} -> throw(:mqttx_invalid_topic)
      end
    end

    flags = dup <<< 3 ||| qos <<< 1 ||| retain

    packet_id_bin =
      case qos do
        0 -> <<>>
        _ -> <<require_packet_id(msg)::16-big>>
      end

    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    payload = Map.get(msg, :payload, <<>>)

    variable = [encode_utf8(topic), packet_id_bin, props, payload]
    {:ok, {<<@publish::4, flags::4>>, variable}}
  end

  # PUBACK, PUBREC, PUBCOMP
  defp encode_packet(version, %{type: type} = msg) when type in [:puback, :pubrec, :pubcomp] do
    type_code = atom_to_type(type)
    packet_id = require_packet_id(msg)
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = encode_ack_response(version, packet_id, reason_code, props)
    {:ok, {<<type_code::4, 0::4>>, variable}}
  end

  # PUBREL
  defp encode_packet(version, %{type: :pubrel} = msg) do
    packet_id = require_packet_id(msg)
    reason_code = Map.get(msg, :reason_code, 0)
    props = Map.get(msg, :properties, %{})

    variable = encode_ack_response(version, packet_id, reason_code, props)
    {:ok, {<<@pubrel::4, 2::4>>, variable}}
  end

  # SUBSCRIBE
  defp encode_packet(version, %{type: :subscribe} = msg) do
    packet_id = require_packet_id(msg)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    topic_list = Map.get(msg, :topics, [])
    if topic_list == [], do: throw(:mqttx_empty_topic_list)
    topics = encode_subscribe_topics(version, topic_list)

    variable = [<<packet_id::16-big>>, props, topics]
    {:ok, {<<@subscribe::4, 2::4>>, variable}}
  end

  # SUBACK
  defp encode_packet(version, %{type: :suback} = msg) do
    packet_id = require_packet_id(msg)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    acks = encode_suback_acks(Map.get(msg, :acks, []))

    variable = [<<packet_id::16-big>>, props, acks]
    {:ok, {<<@suback::4, 0::4>>, variable}}
  end

  # UNSUBSCRIBE
  defp encode_packet(version, %{type: :unsubscribe} = msg) do
    packet_id = require_packet_id(msg)
    props = Properties.encode(version, Map.get(msg, :properties, %{}))
    topic_list = Map.get(msg, :topics, [])
    if topic_list == [], do: throw(:mqttx_empty_topic_list)
    topics = encode_unsubscribe_topics(topic_list)

    variable = [<<packet_id::16-big>>, props, topics]
    {:ok, {<<@unsubscribe::4, 2::4>>, variable}}
  end

  # UNSUBACK
  defp encode_packet(version, %{type: :unsuback} = msg) do
    packet_id = require_packet_id(msg)
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

    variable =
      if reason_code == 0 and map_size(props) == 0 do
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

    variable =
      if reason_code == 0 and map_size(props) == 0 do
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

  # §3.1.2.3: reserved flag bit MUST be 0
  defp validate_connect_flags(1, _, _, _), do: {:error, :malformed_packet}
  # §3.1.2.6/7: if Will Flag = 0, Will QoS and Will Retain MUST be 0
  defp validate_connect_flags(0, 0, 0, 0), do: :ok
  defp validate_connect_flags(0, 0, _, _), do: {:error, :malformed_packet}
  # §3.1.2.6: Will QoS MUST NOT be 3
  defp validate_connect_flags(0, 1, 3, _), do: {:error, :malformed_packet}
  defp validate_connect_flags(0, 1, _, _), do: :ok

  # v3.1.1 §3.1.2.9: if username flag is 0, password flag MUST also be 0. v5 lifts this.
  defp validate_user_pass_flags(4, 0, 1), do: {:error, :malformed_packet}
  defp validate_user_pass_flags(3, 0, 1), do: {:error, :malformed_packet}
  defp validate_user_pass_flags(_, _, _), do: :ok

  defp ensure_nonempty_topics([]), do: {:error, :protocol_error}
  defp ensure_nonempty_topics(_), do: :ok

  defp protocol_name(3), do: @protocol_name_3
  defp protocol_name(_), do: @protocol_name

  # These functions handle all packet types for completeness, but may only be
  # called with a subset of types in specific contexts. Dialyzer warnings suppressed.
  @dialyzer {:nowarn_function, type_to_atom: 1}
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

  # Only the ack types route through here (see encode_packet/2 for
  # :puback/:pubrec/:pubcomp); every other packet type writes its type code
  # literally in its own clause.
  defp atom_to_type(:puback), do: @puback
  defp atom_to_type(:pubrec), do: @pubrec
  defp atom_to_type(:pubcomp), do: @pubcomp

  # MQTT-2.2.1-2/-3: packet ids must be present and non-zero for the packet
  # types that carry one. The throw is caught at the encode boundary.
  defp require_packet_id(msg) do
    case Map.get(msg, :packet_id) do
      id when is_integer(id) and id >= 1 and id <= 0xFFFF -> id
      _ -> throw(:mqttx_missing_packet_id)
    end
  end

  # UTF-8 string encoding/decoding. The 2-byte length prefix caps strings at
  # 65,535 bytes (§1.5.4) — without the guard, `byte_size/1` silently wraps
  # modulo 65536 and corrupts the wire framing. Encode enforces the same
  # §1.5.4 validity rules as decode (no U+0000, no surrogates) so we never
  # emit strings our own decoder — or a strict broker — rejects. Throws are
  # caught at the encode/2 / encode_iodata/2 boundary.
  defp encode_utf8(str) when byte_size(str) > 0xFFFF do
    throw(:mqttx_string_too_long)
  end

  defp encode_utf8(str) when is_binary(str) do
    unless valid_mqtt_utf8?(str), do: throw(:mqttx_invalid_utf8)
    <<byte_size(str)::16-big, str::binary>>
  end

  defp encode_optional_utf8(nil), do: <<>>
  defp encode_optional_utf8(str), do: encode_utf8(str)

  defp encode_optional_binary(nil), do: <<>>
  defp encode_optional_binary(bin), do: encode_length_prefixed_binary(bin)

  # Safe variants used by CONNECT decode — surface malformed inputs as errors instead of MatchError
  defp decode_utf8_safe(<<len::16-big, str::binary-size(len), rest::binary>>) do
    if valid_mqtt_utf8?(str), do: {:ok, str, rest}, else: {:error, :malformed_packet}
  end

  defp decode_utf8_safe(_), do: {:error, :malformed_packet}

  defp decode_utf8_optional_safe(data, 0), do: {:ok, nil, data}
  defp decode_utf8_optional_safe(data, 1), do: decode_utf8_safe(data)

  defp decode_binary_optional_safe(data, 0), do: {:ok, nil, data}

  defp decode_binary_optional_safe(<<len::16-big, bin::binary-size(len), rest::binary>>, 1),
    do: {:ok, bin, rest}

  defp decode_binary_optional_safe(_, _), do: {:error, :malformed_packet}

  # MQTT §1.5.4: UTF-8 strings MUST NOT contain U+0000 (null) or U+D800..U+DFFF (surrogates)
  # `:unicode.characters_to_binary/1` rejects standalone surrogates and ill-formed UTF-8.
  defp valid_mqtt_utf8?(<<>>), do: true

  defp valid_mqtt_utf8?(bin) when is_binary(bin) do
    case :binary.match(bin, <<0>>) do
      :nomatch -> :unicode.characters_to_binary(bin) == bin
      _ -> false
    end
  end

  # Will message encoding
  defp encode_will(_version, nil), do: <<>>

  defp encode_will(version, will) do
    topic =
      case will.topic do
        t when is_list(t) -> Topic.flatten(t)
        t when is_binary(t) -> t
      end

    [
      Properties.encode(version, Map.get(will, :properties, %{})),
      encode_utf8(topic),
      # §3.1.3.4: the Will Payload is BINARY data — length-prefixed but not
      # UTF-8 validated (decode already treats it as binary)
      encode_length_prefixed_binary(Map.get(will, :payload, <<>>))
    ]
  end

  defp encode_length_prefixed_binary(bin) when byte_size(bin) > 0xFFFF do
    throw(:mqttx_string_too_long)
  end

  defp encode_length_prefixed_binary(bin) when is_binary(bin) do
    <<byte_size(bin)::16-big, bin::binary>>
  end

  # ACK payload handling (for MQTT 5.0)
  defp decode_ack_payload(5, <<>>) do
    {:ok, 0, %{}}
  end

  defp decode_ack_payload(5, <<reason_code::8, rest::binary>>) do
    case Properties.decode(5, rest) do
      {:ok, props, <<>>} -> {:ok, reason_code, props}
      {:ok, _props, _trailing} -> {:error, :malformed_packet}
      {:error, _} = err -> err
    end
  end

  defp decode_ack_payload(_version, <<>>) do
    {:ok, 0, %{}}
  end

  # v3/v4 acks carry nothing after the packet id (§3.4 in MQTT 3.1.1)
  defp decode_ack_payload(_version, _trailing) do
    {:error, :malformed_packet}
  end

  defp encode_ack_response(5, packet_id, reason_code, props)
       when reason_code == 0 and map_size(props) == 0 do
    [<<packet_id::16-big>>]
  end

  defp encode_ack_response(5, packet_id, reason_code, props) do
    [<<packet_id::16-big, reason_code::8>>, Properties.encode(5, props)]
  end

  defp encode_ack_response(_version, packet_id, _reason_code, _props) do
    [<<packet_id::16-big>>]
  end

  defp decode_publish_packet_id(0, rest), do: {:ok, nil, rest}
  defp decode_publish_packet_id(_qos, <<pid::16-big, rest::binary>>), do: {:ok, pid, rest}
  defp decode_publish_packet_id(_qos, _), do: {:error, :malformed_packet}

  # MQTT 5.0: empty topic is valid when topic_alias is present
  defp validate_publish_topic("", %{topic_alias: alias_val})
       when is_integer(alias_val) and alias_val > 0 do
    {:ok, ""}
  end

  defp validate_publish_topic(topic, _props) do
    Topic.validate_publish(topic)
  end

  # Subscribe topics
  defp decode_subscribe_topics(_version, <<>>, topics) do
    {:ok, Enum.reverse(topics)}
  end

  defp decode_subscribe_topics(
         version,
         <<len::16-big, name::binary-size(len), opts::8, rest::binary>>,
         topics
       ) do
    <<reserved::2, rh::2, rap::1, nl::1, qos::2>> = <<opts::8>>

    cond do
      # §3.8.3.1: reserved bits MUST be 0; QoS=3 and RH=3 are Malformed Packet
      reserved != 0 or qos == 3 or rh == 3 ->
        {:error, :malformed_packet}

      # v3.1.1 §3.8.3-4: only the QoS bits exist — bits 7-2 MUST be 0.
      # Accepting v5 nl/rap/rh bits here would silently honor semantics the
      # protocol version doesn't have.
      version < 5 and (rh != 0 or rap != 0 or nl != 0) ->
        {:error, :malformed_packet}

      true ->
        case Topic.validate(name) do
          {:ok, normalized} ->
            topic = %{
              topic: normalized,
              qos: qos,
              no_local: nl == 1,
              retain_as_published: rap == 1,
              retain_handling: rh
            }

            decode_subscribe_topics(version, rest, [topic | topics])

          {:error, _} = err ->
            err
        end
    end
  end

  defp decode_subscribe_topics(_version, _other, _topics), do: {:error, :malformed_packet}

  defp encode_subscribe_topics(version, topics) do
    Enum.map(topics, fn topic ->
      name =
        case topic do
          %{topic: t} when is_list(t) -> Topic.flatten(t)
          %{topic: t} when is_binary(t) -> t
          t when is_binary(t) -> t
          t when is_list(t) -> Topic.flatten(t)
        end

      qos = Map.get(topic, :qos, 0)

      # nl/rap/rh exist only in v5 (§3.8.3.1) — emitting them in a v3.1.1
      # SUBSCRIBE produces a packet the broker must reject
      {nl, rap, rh} =
        if version >= 5 do
          {
            if(Map.get(topic, :no_local, false), do: 1, else: 0),
            if(Map.get(topic, :retain_as_published, false), do: 1, else: 0),
            Map.get(topic, :retain_handling, 0)
          }
        else
          {0, 0, 0}
        end

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

  defp decode_unsubscribe_topics(_other, _topics), do: {:error, :malformed_packet}

  defp encode_unsubscribe_topics(topics) do
    Enum.map(topics, fn topic ->
      name =
        case topic do
          t when is_list(t) -> Topic.flatten(t)
          t when is_binary(t) -> t
        end

      encode_utf8(name)
    end)
  end

  # SUBACK acks
  # §3.9.3: the SUBACK payload MUST contain at least one reason code
  defp decode_suback_acks(<<>>, []), do: {:error, :malformed_packet}

  defp decode_suback_acks(<<>>, acks) do
    {:ok, Enum.reverse(acks)}
  end

  defp decode_suback_acks(<<0, rest::binary>>, acks),
    do: decode_suback_acks(rest, [{:ok, 0} | acks])

  defp decode_suback_acks(<<1, rest::binary>>, acks),
    do: decode_suback_acks(rest, [{:ok, 1} | acks])

  defp decode_suback_acks(<<2, rest::binary>>, acks),
    do: decode_suback_acks(rest, [{:ok, 2} | acks])

  defp decode_suback_acks(<<reason::8, rest::binary>>, acks) when reason >= 0x80 do
    decode_suback_acks(rest, [{:error, reason} | acks])
  end

  # Invalid SUBACK byte (0x03..0x7F): surface as error rather than crash
  defp decode_suback_acks(<<_invalid::8, _rest::binary>>, _acks),
    do: {:error, :malformed_packet}

  defp encode_suback_acks(acks) do
    Enum.map(acks, fn
      {:ok, qos} when qos in [0, 1, 2] -> <<0::6, qos::2>>
      {:error, reason} when reason >= 0x80 -> <<reason::8>>
    end)
  end

  # UNSUBACK acks
  # §3.11.3 (v5): the UNSUBACK payload MUST contain at least one reason code.
  # v3.1.1 UNSUBACK has no payload, so [] is only rejected for v5 (see caller).
  defp decode_unsuback_acks(<<>>, acks) do
    {:ok, Enum.reverse(acks)}
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

  # Invalid UNSUBACK byte: surface as error rather than crash
  defp decode_unsuback_acks(<<_invalid::8, _rest::binary>>, _acks),
    do: {:error, :malformed_packet}

  defp encode_unsuback_acks(acks) do
    Enum.map(acks, fn
      {:ok, :found} -> <<0>>
      {:ok, :notfound} -> <<17>>
      {:error, reason} when reason >= 0x80 -> <<reason::8>>
    end)
  end
end
