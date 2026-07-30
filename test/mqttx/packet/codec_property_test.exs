defmodule MqttX.Packet.CodecPropertyTest do
  # Property-based tests for the wire codec: round-trip fidelity and
  # "decode never raises" over arbitrary input — the class of
  # MatchError/FunctionClauseError-on-malformed bugs this codec has
  # historically accumulated.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MqttX.Packet.Codec

  # Topic segments: non-empty UTF-8 without null, wildcards, or '/'
  defp topic_gen do
    gen all(
          segments <-
            list_of(
              string(:alphanumeric, min_length: 1, max_length: 12),
              min_length: 1,
              max_length: 5
            )
        ) do
      Enum.join(segments, "/")
    end
  end

  property "PUBLISH round-trips through encode/decode (v4 and v5)" do
    check all(
            topic <- topic_gen(),
            payload <- binary(max_length: 256),
            qos <- member_of([0, 1, 2]),
            retain <- boolean(),
            version <- member_of([4, 5]),
            packet_id <- integer(1..0xFFFF)
          ) do
      packet = %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: qos,
        retain: retain,
        dup: false,
        packet_id: if(qos > 0, do: packet_id, else: nil),
        properties: %{}
      }

      assert {:ok, encoded} = Codec.encode(version, packet)
      assert {:ok, {decoded, <<>>}} = Codec.decode(version, encoded)

      assert decoded.topic == MqttX.Topic.normalize(topic)
      assert decoded.payload == payload
      assert decoded.qos == qos
      assert decoded.retain == retain
      if qos > 0, do: assert(decoded.packet_id == packet_id)
    end
  end

  property "SUBSCRIBE round-trips (v5 keeps subscription options)" do
    check all(
            topic <- topic_gen(),
            qos <- member_of([0, 1, 2]),
            nl <- boolean(),
            rap <- boolean(),
            rh <- member_of([0, 1, 2]),
            packet_id <- integer(1..0xFFFF)
          ) do
      packet = %{
        type: :subscribe,
        packet_id: packet_id,
        topics: [
          %{topic: topic, qos: qos, no_local: nl, retain_as_published: rap, retain_handling: rh}
        ],
        properties: %{}
      }

      assert {:ok, encoded} = Codec.encode(5, packet)
      assert {:ok, {decoded, <<>>}} = Codec.decode(5, encoded)

      [sub] = decoded.topics
      assert sub.qos == qos
      assert sub.no_local == nl
      assert sub.retain_as_published == rap
      assert sub.retain_handling == rh
    end
  end

  property "decode never raises on arbitrary bytes" do
    check all(
            data <- binary(max_length: 512),
            version <- member_of([3, 4, 5]),
            max_runs: 500
          ) do
      # Any result tuple is fine — raising is the bug
      case Codec.decode(version, data) do
        {:ok, {packet, rest}} when is_map(packet) and is_binary(rest) -> :ok
        {:error, reason} when is_atom(reason) -> :ok
      end
    end
  end

  property "all ack-family packets round-trip with reason codes and properties (v5)" do
    check all(
            type <- member_of([:puback, :pubrec, :pubrel, :pubcomp]),
            packet_id <- integer(1..0xFFFF),
            reason_code <- member_of([0x00, 0x10, 0x80, 0x83, 0x87, 0x92, 0x97]),
            reason_string <- string(:alphanumeric, max_length: 20)
          ) do
      props = if reason_string == "", do: %{}, else: %{reason_string: reason_string}

      packet = %{
        type: type,
        packet_id: packet_id,
        reason_code: reason_code,
        properties: props
      }

      assert {:ok, encoded} = Codec.encode(5, packet)
      assert {:ok, {decoded, <<>>}} = Codec.decode(5, encoded)
      assert decoded.type == type
      assert decoded.packet_id == packet_id
      assert decoded.reason_code == reason_code
    end
  end

  property "CONNECT round-trips with credentials, will, and keepalive" do
    check all(
            client_id <- string(:alphanumeric, min_length: 1, max_length: 23),
            keepalive <- integer(0..0xFFFF),
            clean <- boolean(),
            username <-
              one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 12)]),
            will_topic <- topic_gen(),
            will_payload <- binary(max_length: 64),
            will_qos <- member_of([0, 1, 2]),
            version <- member_of([4, 5])
          ) do
      packet = %{
        type: :connect,
        protocol_version: version,
        client_id: client_id,
        clean_session: clean,
        keep_alive: keepalive,
        username: username,
        # password requires username per §3.1.2.9 (v3.1.1)
        password: if(username, do: "secret", else: nil),
        will: %{
          topic: will_topic,
          payload: will_payload,
          qos: will_qos,
          retain: false,
          properties: %{}
        },
        properties: %{}
      }

      assert {:ok, encoded} = Codec.encode(version, packet)
      assert {:ok, {decoded, <<>>}} = Codec.decode(version, encoded)
      assert decoded.client_id == client_id
      assert decoded.keep_alive == keepalive
      assert decoded.clean_session == clean
      assert decoded.username == username
      assert decoded.will.qos == will_qos
      assert decoded.will.payload == will_payload
    end
  end

  property "DISCONNECT and AUTH round-trip with properties (v5)" do
    check all(
            type <- member_of([:disconnect, :auth]),
            reason_code <- member_of([0x00, 0x04, 0x18, 0x81, 0x8E, 0x94]),
            reason_string <- string(:alphanumeric, max_length: 16)
          ) do
      # AUTH only accepts 0x00/0x18/0x19 semantics but the codec is a
      # transparent carrier for the byte
      props = if reason_string == "", do: %{}, else: %{reason_string: reason_string}
      packet = %{type: type, reason_code: reason_code, properties: props}

      assert {:ok, encoded} = Codec.encode(5, packet)
      assert {:ok, {decoded, <<>>}} = Codec.decode(5, encoded)
      assert decoded.type == type
      assert decoded.reason_code == reason_code
    end
  end

  property "v5 property maps round-trip through Properties encode/decode" do
    alias MqttX.Packet.Properties

    check all(
            expiry <- integer(1..0xFFFFFFFF),
            receive_max <- integer(1..0xFFFF),
            topic_alias <- integer(1..0xFFFF),
            content_type <- string(:alphanumeric, min_length: 1, max_length: 16),
            user_key <- string(:alphanumeric, min_length: 1, max_length: 8),
            user_val <- string(:alphanumeric, max_length: 8)
          ) do
      props = %{
        message_expiry_interval: expiry,
        receive_maximum: receive_max,
        topic_alias: topic_alias,
        content_type: content_type,
        user_properties: [{user_key, user_val}]
      }

      encoded = IO.iodata_to_binary(Properties.encode(5, props))
      assert {:ok, decoded, <<>>} = Properties.decode(5, encoded)

      assert decoded.message_expiry_interval == expiry
      assert decoded.receive_maximum == receive_max
      assert decoded.topic_alias == topic_alias
      assert decoded.content_type == content_type
      assert decoded.user_properties == [{user_key, user_val}]
    end
  end

  property "Properties.decode never raises on arbitrary bytes" do
    alias MqttX.Packet.Properties

    check all(data <- binary(max_length: 128), max_runs: 500) do
      case Properties.decode(5, data) do
        {:ok, props, rest} when is_map(props) and is_binary(rest) -> :ok
        {:error, reason} when is_atom(reason) -> :ok
      end
    end
  end

  property "Varint round-trips over its full domain" do
    alias MqttX.Packet.Varint

    check all(n <- integer(0..268_435_455)) do
      encoded = Varint.encode(n)
      assert {:ok, ^n, <<>>} = Varint.decode(IO.iodata_to_binary(encoded))
    end
  end

  property "encode returns a tagged tuple (never raises) on adversarial field values" do
    check all(
            type <- member_of([:publish, :subscribe, :puback, :connect, :disconnect]),
            packet_id <- one_of([constant(nil), constant(0), integer(-5..70_000)]),
            qos <- integer(-1..5),
            topic <- one_of([topic_gen(), constant(""), constant("bad/#"), constant("a/+/b")]),
            version <- member_of([4, 5])
          ) do
      packet = %{
        type: type,
        protocol_version: version,
        client_id: "prop-test",
        clean_session: true,
        keep_alive: 60,
        username: nil,
        password: nil,
        will: nil,
        topic: topic,
        topics: [%{topic: topic, qos: 1}],
        payload: "x",
        qos: qos,
        retain: false,
        dup: false,
        packet_id: packet_id,
        reason_code: 0,
        properties: %{}
      }

      # Invalid combinations must surface as {:error, _}, never as a raise
      case Codec.encode(version, packet) do
        {:ok, bin} when is_binary(bin) -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  property "decode never raises on corrupted valid packets" do
    check all(
            topic <- topic_gen(),
            payload <- binary(max_length: 64),
            flip_pos <- integer(0..63),
            flip_bit <- integer(0..7),
            version <- member_of([4, 5])
          ) do
      {:ok, encoded} =
        Codec.encode(version, %{
          type: :publish,
          topic: topic,
          payload: payload,
          qos: 0,
          retain: false,
          dup: false,
          properties: %{}
        })

      pos = rem(flip_pos, byte_size(encoded))
      <<pre::binary-size(^pos), byte, post::binary>> = encoded
      corrupted = <<pre::binary, Bitwise.bxor(byte, Bitwise.bsl(1, flip_bit)), post::binary>>

      case Codec.decode(version, corrupted) do
        {:ok, {packet, rest}} when is_map(packet) and is_binary(rest) -> :ok
        {:error, reason} when is_atom(reason) -> :ok
      end
    end
  end
end
