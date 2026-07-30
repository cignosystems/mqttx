defmodule MqttX.Packet.CodecMalformedTest do
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec

  describe "trailing bytes after properties (must not raise)" do
    test "v5 CONNACK with trailing byte after properties" do
      # props length 0, then a stray 0xFF inside the declared remaining length
      assert {:error, :malformed_packet} = Codec.decode(5, <<2::4, 0::4, 4, 0, 0, 0, 0xFF>>)
    end

    test "v5 PUBACK with trailing byte after properties" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<4::4, 0::4, 5, 0, 1, 0, 0, 0xAA>>)
    end

    test "v5 PUBREC/PUBREL/PUBCOMP with trailing byte after properties" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<5::4, 0::4, 5, 0, 1, 0, 0, 0xAA>>)
      assert {:error, :malformed_packet} = Codec.decode(5, <<6::4, 2::4, 5, 0, 1, 0, 0, 0xAA>>)
      assert {:error, :malformed_packet} = Codec.decode(5, <<7::4, 0::4, 5, 0, 1, 0, 0, 0xAA>>)
    end

    test "v4 DISCONNECT with payload bytes" do
      assert {:error, :malformed_packet} = Codec.decode(4, <<14::4, 0::4, 2, 0, 0>>)
    end

    test "v5 DISCONNECT with trailing byte after properties" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<14::4, 0::4, 3, 0, 0, 0xFF>>)
    end

    test "v5 AUTH with trailing byte after properties" do
      assert {:error, :malformed_packet} = Codec.decode(5, <<15::4, 0::4, 3, 0, 0, 0xFF>>)
    end
  end

  describe "v3/v4 acks with extra payload (must not raise)" do
    test "v4 PUBACK with bytes after the packet id" do
      assert {:error, :malformed_packet} = Codec.decode(4, <<4::4, 0::4, 3, 0, 1, 0xAA>>)
    end

    test "v4 PUBREC/PUBREL/PUBCOMP with bytes after the packet id" do
      assert {:error, :malformed_packet} = Codec.decode(4, <<5::4, 0::4, 3, 0, 1, 0xAA>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<6::4, 2::4, 3, 0, 1, 0xAA>>)
      assert {:error, :malformed_packet} = Codec.decode(4, <<7::4, 0::4, 3, 0, 1, 0xAA>>)
    end

    test "v3 PUBACK with bytes after the packet id" do
      assert {:error, :malformed_packet} = Codec.decode(3, <<4::4, 0::4, 3, 0, 1, 0xAA>>)
    end
  end

  describe "malformed bytes inside a complete packet are not :incomplete" do
    test "PUBLISH whose property length exceeds the remaining payload" do
      # remaining length 8: topic "a/b" (5 bytes), prop-length varint says 20,
      # only 2 bytes actually present — complete slice, malformed content
      packet = <<3::4, 0::4, 8, 0, 3, "a/b", 20, "xx">>
      assert {:error, :malformed_packet} = Codec.decode(5, packet)
    end

    test "truncated UTF-8 string inside a complete CONNECT" do
      # client_id length claims 10 with only 2 bytes present in the slice
      var_header = <<0, 4, "MQTT", 4, 0b00000010, 0, 60>>
      payload = <<0, 10, "ab">>
      remaining = byte_size(var_header) + byte_size(payload)
      packet = <<1::4, 0::4, remaining, var_header::binary, payload::binary>>
      assert {:error, :malformed_packet} = Codec.decode(4, packet)
    end

    test "genuinely partial packets still report :incomplete" do
      {:ok, full} = Codec.encode(4, %{type: :pingreq})
      assert {:error, :incomplete} = Codec.decode(4, binary_part(full, 0, 1))

      {:ok, pub} =
        Codec.encode(4, %{
          type: :publish,
          topic: "a/b",
          payload: "hello",
          qos: 0,
          retain: false,
          dup: false,
          properties: %{}
        })

      for cut <- 1..(byte_size(pub) - 1) do
        assert {:error, :incomplete} = Codec.decode(4, binary_part(pub, 0, cut)),
               "expected :incomplete at cut #{cut}"
      end
    end
  end

  describe "SUBACK/UNSUBACK ack validation" do
    test "SUBACK with an invalid reason byte is malformed, not buried in acks" do
      # v4 SUBACK, packet id 1, reason byte 0x03 (invalid: not 0-2, not >= 0x80)
      assert {:error, :malformed_packet} = Codec.decode(4, <<9::4, 0::4, 3, 0, 1, 3>>)
    end

    test "empty SUBACK ack list is malformed (§3.9.3)" do
      assert {:error, :malformed_packet} = Codec.decode(4, <<9::4, 0::4, 2, 0, 1>>)
    end

    test "empty v5 UNSUBACK ack list is malformed; v4 UNSUBACK without payload is fine" do
      # v5: packet id + empty properties, no reason codes
      assert {:error, :malformed_packet} = Codec.decode(5, <<11::4, 0::4, 3, 0, 1, 0>>)
      # v4: UNSUBACK is just the packet id
      assert {:ok, {%{type: :unsuback}, <<>>}} = Codec.decode(4, <<11::4, 0::4, 2, 0, 1>>)
    end
  end

  describe "encode length guards (16-bit fields must not wrap)" do
    test "oversized topic returns an error instead of corrupt framing" do
      big_topic = String.duplicate("x", 65_536)

      # Rejected by topic validation before the length prefix could wrap
      assert {:error, :invalid_topic} =
               Codec.encode(4, %{
                 type: :publish,
                 topic: big_topic,
                 payload: "p",
                 qos: 0,
                 retain: false,
                 dup: false,
                 properties: %{}
               })
    end

    test "oversized client_id returns an error" do
      assert {:error, :string_too_long} =
               Codec.encode(4, %{
                 type: :connect,
                 protocol_version: 4,
                 client_id: String.duplicate("c", 70_000),
                 username: nil,
                 password: nil,
                 will: nil,
                 clean_session: true,
                 keep_alive: 60,
                 properties: %{}
               })
    end

    test "oversized v5 string property returns an error" do
      assert {:error, :string_too_long} =
               Codec.encode(5, %{
                 type: :disconnect,
                 reason_code: 0x80,
                 properties: %{reason_string: String.duplicate("r", 66_000)}
               })
    end

    test "a topic just under the cap still encodes" do
      topic = String.duplicate("x", 65_535)

      assert {:ok, encoded} =
               Codec.encode(4, %{
                 type: :publish,
                 topic: topic,
                 payload: "",
                 qos: 0,
                 retain: false,
                 dup: false,
                 properties: %{}
               })

      assert {:ok, {%{type: :publish}, <<>>}} = Codec.decode(4, encoded)
    end
  end

  describe "Topic.validate list form respects the 65535-byte cap" do
    test "two 40k segments are rejected" do
      seg = String.duplicate("x", 40_000)
      assert {:error, :invalid_topic} = MqttX.Topic.validate([seg, seg])
    end

    test "normal list topics still validate" do
      assert {:ok, _} = MqttX.Topic.validate(["sensors", "room1", "temp"])
    end
  end

  describe "truncated varint inside a property slice (found by property fuzzing)" do
    # Varint.decode/1 returns a BARE :incomplete, and the
    # subscription_identifier decoder's `with` had no `else`, so that atom
    # escaped to Properties.decode/2's `case` and raised CaseClauseError —
    # remotely triggerable with 8 bytes, on both client and server.
    test "subscription_identifier with no varint bytes is malformed, not a crash" do
      # v5 PUBLISH, topic "a/b", property length 1, property id 0x0B, nothing after
      assert {:error, :malformed_packet} =
               Codec.decode(5, <<0x30, 7, 0, 3, "a/b", 1, 0x0B>>)
    end

    test "subscription_identifier with an unterminated varint is malformed" do
      assert {:error, :malformed_packet} =
               Codec.decode(5, <<0x30, 8, 0, 3, "a/b", 2, 0x0B, 0xFF>>)
    end

    test "the original fuzzer counterexample decodes to an error" do
      packet =
        <<48, 52, 0, 24>> <>
          "kksxncjxusqq/zuzm/j/opie" <>
          <<1, 11, 127, 250, 115, 143, 34, 219, 206, 163, 166, 30, 177, 7, 227, 128, 37, 197, 172,
            26, 87, 85, 194, 81, 53, 223>>

      assert {:error, :malformed_packet} = Codec.decode(5, packet)
    end

    test "a valid subscription_identifier still round-trips" do
      {:ok, encoded} =
        Codec.encode(5, %{
          type: :publish,
          topic: "a/b",
          payload: "x",
          qos: 0,
          retain: false,
          dup: false,
          properties: %{subscription_identifier: 42}
        })

      assert {:ok, {decoded, <<>>}} = Codec.decode(5, encoded)
      assert decoded.properties.subscription_identifier == 42
    end
  end

  describe "declared_length/1" do
    test "reports header + remaining length without decoding the body" do
      assert {:ok, 2} = Codec.declared_length(<<12::4, 0::4, 0>>)
      # declared 256 MB body from a 5-byte prefix
      assert {:ok, 268_435_460} =
               Codec.declared_length(<<3::4, 0::4, 0xFF, 0xFF, 0xFF, 0x7F>>)
    end

    test "incomplete while the varint itself is partial" do
      assert :incomplete = Codec.declared_length(<<>>)
      assert :incomplete = Codec.declared_length(<<3::4, 0::4>>)
      assert :incomplete = Codec.declared_length(<<3::4, 0::4, 0xFF>>)
    end

    test "malformed on a 5-byte varint" do
      assert {:error, :malformed_header} =
               Codec.declared_length(<<3::4, 0::4, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>)
    end
  end
end
