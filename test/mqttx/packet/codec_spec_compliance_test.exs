defmodule MqttX.Packet.CodecSpecComplianceTest do
  # Wire-level conformance fixes verified against the OASIS MQTT 3.1.1 / 5.0
  # texts. Each `describe` cites the clause it enforces; the packets are built
  # by hand so a test cannot be fooled by a matching bug in the encoder.
  use ExUnit.Case, async: true

  alias MqttX.Packet.{Codec, Properties}

  @publish %{
    type: :publish,
    topic: "a",
    qos: 0,
    retain: false,
    dup: false,
    packet_id: nil,
    payload: "",
    properties: %{}
  }

  @connect %{
    type: :connect,
    protocol_version: 4,
    client_id: "c",
    clean_session: true,
    keep_alive: 0,
    username: nil,
    password: nil,
    will: nil,
    properties: %{}
  }

  describe "UNSUBACK encoding (MQTT 3.1.1 §3.11)" do
    test "v3/v4 UNSUBACK is the packet id alone — acks are not on the wire" do
      msg = %{type: :unsuback, packet_id: 1, acks: [{:ok, :found}]}
      assert {:ok, <<176, 2, 0, 1>>} = Codec.encode(4, msg)
      assert {:ok, <<176, 2, 0, 1>>} = Codec.encode(3, msg)

      # Several acks still collapse to remaining length 2
      assert {:ok, <<176, 2, 0, 7>>} =
               Codec.encode(4, %{
                 type: :unsuback,
                 packet_id: 7,
                 acks: [{:ok, :found}, {:ok, :notfound}]
               })
    end

    test "v5 UNSUBACK keeps its properties and reason codes" do
      assert {:ok, <<176, 4, 0, 1, 0, 0>>} =
               Codec.encode(5, %{type: :unsuback, packet_id: 1, acks: [{:ok, :found}]})
    end

    test "a v4 UNSUBACK round-trips and decode stays lenient about trailing bytes" do
      {:ok, bin} = Codec.encode(4, %{type: :unsuback, packet_id: 1, acks: [{:ok, :found}]})
      assert {:ok, {%{type: :unsuback, packet_id: 1, acks: []}, <<>>}} = Codec.decode(4, bin)

      assert {:ok, {%{type: :unsuback, packet_id: 1}, <<>>}} =
               Codec.decode(4, <<176, 4, 0, 1, 0, 0>>)
    end
  end

  describe "v5 ack with reason code but no Property Length (§3.4.2.2.1 et al.)" do
    test "PUBACK/PUBREC/PUBREL/PUBCOMP with Remaining Length 3 decode with empty properties" do
      for {byte, type} <- [{0x40, :puback}, {0x50, :pubrec}, {0x62, :pubrel}, {0x70, :pubcomp}] do
        assert {:ok, {decoded, <<>>}} = Codec.decode(5, <<byte, 3, 0, 1, 0x10>>),
               "#{type} short form must decode"

        assert decoded.type == type
        assert decoded.packet_id == 1
        assert decoded.reason_code == 0x10
        assert decoded.properties == %{}
      end
    end

    test "the 2-byte and full forms keep working" do
      assert {:ok, {%{type: :puback, reason_code: 0, properties: %{}}, <<>>}} =
               Codec.decode(5, <<0x40, 2, 0, 1>>)

      assert {:ok, {%{type: :puback, reason_code: 0x10, properties: %{}}, <<>>}} =
               Codec.decode(5, <<0x40, 4, 0, 1, 0x10, 0>>)

      assert {:ok,
              {%{type: :puback, reason_code: 0x10, properties: %{reason_string: "ok"}}, <<>>}} =
               Codec.decode(5, <<0x40, 9, 0, 1, 0x10, 5, 0x1F, 0, 2, "ok">>)
    end
  end

  describe "Packet Identifier 0 is malformed on PUBLISH/SUBSCRIBE/UNSUBSCRIBE (MQTT-2.2.1-3)" do
    test "PUBLISH with QoS > 0 and id 0" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<0x32, 6, 0, 1, ?a, 0, 0, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(5, <<0x34, 6, 0, 1, ?a, 0, 0, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<0x32, 5, 0, 1, ?a, 0, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(3, <<0x32, 5, 0, 1, ?a, 0, 0>>)

      # id 1 in the same shape is fine
      assert {:ok, {%{packet_id: 1}, <<>>}} = Codec.decode(5, <<0x32, 6, 0, 1, ?a, 0, 1, 0>>)
    end

    test "SUBSCRIBE with id 0" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<0x82, 7, 0, 0, 0, 0, 1, ?a, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<0x82, 6, 0, 0, 0, 1, ?a, 0>>)
      assert {:ok, {%{packet_id: 1}, <<>>}} = Codec.decode(5, <<0x82, 7, 0, 1, 0, 0, 1, ?a, 0>>)
    end

    test "UNSUBSCRIBE with id 0" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<0xA2, 6, 0, 0, 0, 0, 1, ?a>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<0xA2, 5, 0, 0, 0, 1, ?a>>)
      assert {:ok, {%{packet_id: 1}, <<>>}} = Codec.decode(5, <<0xA2, 6, 0, 1, 0, 0, 1, ?a>>)
    end

    test "ack packets are untouched — an unknown id is the protocol layer's business" do
      assert {:ok, {%{type: :puback, packet_id: 0}, <<>>}} = Codec.decode(5, <<0x40, 2, 0, 0>>)
      assert {:ok, {%{type: :pubrel, packet_id: 0}, <<>>}} = Codec.decode(4, <<0x62, 2, 0, 0>>)
    end
  end

  describe "UTF-8 string properties are validated on encode (MQTT-1.5.4-1/-2, MQTT-1.5.7-1)" do
    test "a user property key containing U+0000 is rejected" do
      props = %{user_properties: [{<<"k", 0>>, "v"}]}
      assert {:error, :invalid_utf8} = Codec.encode(5, %{@publish | properties: props})
      assert {:error, :invalid_utf8} = Codec.encode_iodata(5, %{@publish | properties: props})
    end

    test "a user property value that is not well-formed UTF-8 is rejected" do
      props = %{user_properties: [{"k", <<0xFF>>}]}
      assert {:error, :invalid_utf8} = Codec.encode(5, %{@publish | properties: props})
    end

    test "the legacy binary-key user property form is validated too" do
      assert {:error, :invalid_utf8} =
               Codec.encode(5, %{@publish | properties: %{<<"k", 0>> => "v"}})
    end

    test "an encoded surrogate (U+D800) in content_type is rejected" do
      props = %{content_type: <<0xED, 0xA0, 0x80>>}
      assert {:error, :invalid_utf8} = Codec.encode(5, %{@publish | properties: props})
    end

    test "every UTF-8 string property applies the rule" do
      assert {:error, :invalid_utf8} =
               Codec.encode(5, %{
                 type: :disconnect,
                 reason_code: 0x80,
                 properties: %{reason_string: <<"bad", 0>>}
               })

      assert {:error, :invalid_utf8} =
               Codec.encode(5, %{@publish | properties: %{response_topic: <<0xC0, 0x80>>}})

      assert {:error, :invalid_utf8} =
               Codec.encode(5, %{type: :auth, properties: %{authentication_method: <<0xFE>>}})
    end

    test "encode now fails exactly where our decoder already rejected the bytes" do
      bad = <<0xED, 0xA0, 0x80>>
      props_bin = <<0x03, 0, 3, bad::binary>>
      wire = <<byte_size(props_bin)>> <> props_bin

      assert {:error, :malformed_packet} = Properties.decode(5, wire)
      assert catch_throw(Properties.encode(5, %{content_type: bad})) == :mqttx_invalid_utf8
    end

    test "well-formed non-ASCII strings still encode and round-trip" do
      props = %{content_type: "日本語", user_properties: [{"ключ", "värde"}]}
      assert {:ok, bin} = Codec.encode(5, %{@publish | properties: props})
      assert {:ok, {%{properties: decoded}, <<>>}} = Codec.decode(5, bin)
      assert decoded.content_type == "日本語"
      assert decoded.user_properties == [{"ключ", "värde"}]
    end
  end

  describe "malformed $share filters are rejected at the SUBSCRIBE/UNSUBSCRIBE decoders (§4.8.2)" do
    test "SUBSCRIBE for \"$share//t\" fails" do
      assert {:error, :invalid_topic} =
               Codec.decode(5, <<0x82, 15, 0, 1, 0, 0, 9, "$share//t", 0>>)
    end

    test "UNSUBSCRIBE for \"$share/g\" fails" do
      assert {:error, :invalid_topic} = Codec.decode(5, <<0xA2, 13, 0, 1, 0, 0, 8, "$share/g">>)
    end

    test "a well-formed shared filter still decodes" do
      assert {:ok, {%{topics: [%{topic: ["$share", "g", :multi_level]}]}, <<>>}} =
               Codec.decode(5, <<0x82, 16, 0, 1, 0, 0, 10, "$share/g/#", 0>>)
    end
  end

  describe "No Local on a Shared Subscription is a Protocol Error (MQTT-3.8.3-4)" do
    test "options byte 0x04 on a $share filter" do
      assert {:error, :protocol_error} =
               Codec.decode(5, <<0x82, 16, 0, 1, 0, 0, 10, "$share/g/t", 0x04>>)

      # nl together with other v5 options
      assert {:error, :protocol_error} =
               Codec.decode(5, <<0x82, 16, 0, 1, 0, 0, 10, "$share/g/t", 0x0C>>)
    end

    test "the same filter without No Local, and No Local on a normal filter, both decode" do
      assert {:ok, {%{topics: [%{no_local: false}]}, <<>>}} =
               Codec.decode(5, <<0x82, 16, 0, 1, 0, 0, 10, "$share/g/t", 0x00>>)

      assert {:ok, {%{topics: [%{no_local: true}]}, <<>>}} =
               Codec.decode(5, <<0x82, 7, 0, 1, 0, 0, 1, ?a, 0x04>>)
    end
  end

  describe "repeated Subscription Identifier in SUBSCRIBE is a Protocol Error (§3.8.2.1.2)" do
    test "two identifiers in one SUBSCRIBE" do
      assert {:error, :protocol_error} =
               Codec.decode(5, <<0x82, 11, 0, 1, 4, 0x0B, 1, 0x0B, 2, 0, 1, ?a, 0>>)
    end

    test "a single identifier decodes to a scalar" do
      assert {:ok, {%{properties: %{subscription_identifier: 7}}, <<>>}} =
               Codec.decode(5, <<0x82, 9, 0, 1, 2, 0x0B, 7, 0, 1, ?a, 0>>)
    end

    test "PUBLISH may still carry several identifiers" do
      assert {:ok, {%{properties: %{subscription_identifier: [1, 2]}}, <<>>}} =
               Codec.decode(5, <<0x30, 8, 0, 1, ?a, 4, 0x0B, 1, 0x0B, 2>>)
    end
  end

  describe "Will Topic is a Topic Name (§3.1.3.3 / §4.7)" do
    # CONNECT with Will Flag set, Will QoS 0, clean session, keep alive 60.
    defp connect_with_will_topic(4, topic) do
      body =
        <<0, 4, "MQTT", 4, 0b00000110, 0, 60>> <>
          <<0, 1, "c">> <> <<byte_size(topic)::16, topic::binary>> <> <<0, 0>>

      <<0x10, byte_size(body), body::binary>>
    end

    defp connect_with_will_topic(5, topic) do
      body =
        <<0, 4, "MQTT", 5, 0b00000110, 0, 60, 0>> <>
          <<0, 1, "c">> <> <<0>> <> <<byte_size(topic)::16, topic::binary>> <> <<0, 0>>

      <<0x10, byte_size(body), body::binary>>
    end

    test "a wildcard Will Topic fails CONNECT decode like a wildcard PUBLISH topic" do
      for version <- [4, 5], topic <- ["a/#", "a/+", "+", "#"] do
        assert {:error, :invalid_topic} =
                 Codec.decode(version, connect_with_will_topic(version, topic)),
               "v#{version} will topic #{inspect(topic)} must be rejected"
      end
    end

    test "an empty Will Topic is rejected" do
      assert {:error, :invalid_topic} = Codec.decode(4, connect_with_will_topic(4, ""))
      assert {:error, :invalid_topic} = Codec.decode(5, connect_with_will_topic(5, ""))
    end

    test "a plain Will Topic still decodes as the original string" do
      assert {:ok, {%{will: %{topic: "a/b"}}, <<>>}} =
               Codec.decode(5, connect_with_will_topic(5, "a/b"))
    end

    test "the encoder refuses to emit a wildcard Will Topic" do
      will = %{topic: "a/#", payload: "", qos: 0, retain: false, properties: %{}}
      assert {:error, :invalid_topic} = Codec.encode(5, %{@connect | will: will})
    end
  end

  describe "CONNACK reserved flag bits (§3.2.2.1.1)" do
    test "non-zero bits 7-1 are malformed for v4 and v5" do
      assert {:error, :malformed_packet} = Codec.decode(4, <<0x20, 2, 0x02, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<0x20, 2, 0x80, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(3, <<0x20, 2, 0xFE, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(5, <<0x20, 3, 0x02, 0, 0>>)
      assert {:error, :malformed_packet} = Codec.decode(5, <<0x20, 3, 0x81, 0, 0>>)
    end

    test "bit 0 alone is Session Present" do
      assert {:ok, {%{session_present: true, reason_code: 0}, <<>>}} =
               Codec.decode(4, <<0x20, 2, 0x01, 0>>)

      assert {:ok, {%{session_present: false, reason_code: 0x86}, <<>>}} =
               Codec.decode(5, <<0x20, 3, 0x00, 0x86, 0>>)
    end
  end

  describe "encoder refuses packets the receiver must reject" do
    test "Will QoS 3 (MQTT-3.1.2-14)" do
      will = %{topic: "w", payload: "", qos: 3, retain: false, properties: %{}}
      assert {:error, :invalid_qos} = Codec.encode(4, %{@connect | will: will})

      assert {:error, :invalid_qos} =
               Codec.encode(5, %{@connect | will: will, protocol_version: 5})
    end

    test "SUBSCRIBE requested QoS 3 (§3.8.3-4 / §3.8.3.1)" do
      sub = %{type: :subscribe, packet_id: 1, topics: [%{topic: "a", qos: 3}], properties: %{}}
      assert {:error, :invalid_qos} = Codec.encode(4, sub)
      assert {:error, :invalid_qos} = Codec.encode(5, sub)
    end

    test "SUBSCRIBE Retain Handling 3 (§3.8.3.1)" do
      sub = %{
        type: :subscribe,
        packet_id: 1,
        topics: [%{topic: "a", qos: 0, retain_handling: 3}],
        properties: %{}
      }

      assert {:error, :value_out_of_range} = Codec.encode(5, sub)
    end

    test "PUBLISH with DUP set at QoS 0 (§3.3.1.1)" do
      assert {:error, :dup_requires_qos} = Codec.encode(4, %{@publish | dup: true})
      assert {:error, :dup_requires_qos} = Codec.encode(5, %{@publish | dup: true})

      assert {:ok, _} = Codec.encode(4, %{@publish | dup: true, qos: 1, packet_id: 1})
    end

    test "v3/v4 CONNECT with a password but no user name (MQTT-3.1.2-22); v5 allows it" do
      assert {:error, :password_without_username} = Codec.encode(4, %{@connect | password: "p"})

      assert {:error, :password_without_username} =
               Codec.encode(3, %{@connect | password: "p", protocol_version: 3})

      assert {:ok, bin} = Codec.encode(5, %{@connect | password: "p", protocol_version: 5})
      assert {:ok, {%{username: nil, password: "p"}, <<>>}} = Codec.decode(5, bin)
    end
  end
end
