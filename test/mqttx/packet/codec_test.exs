defmodule MqttX.Packet.CodecTest do
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec

  describe "CONNECT packet" do
    test "encodes and decodes MQTT 3.1.1 CONNECT" do
      packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "test-client",
        clean_session: true,
        keep_alive: 60,
        username: nil,
        password: nil,
        will: nil,
        properties: %{}
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :connect
      assert decoded.protocol_version == 4
      assert decoded.client_id == "test-client"
      assert decoded.clean_session == true
      assert decoded.keep_alive == 60
    end

    test "encodes CONNECT with will message" do
      packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "test-client",
        clean_session: true,
        keep_alive: 60,
        will: %{
          topic: "test/will",
          payload: "goodbye",
          qos: 1,
          retain: false
        }
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.will.topic == "test/will"
      assert decoded.will.payload == "goodbye"
      assert decoded.will.qos == 1
      assert decoded.will.retain == false
    end

    test "encodes CONNECT with username and password" do
      packet = %{
        type: :connect,
        protocol_version: 4,
        client_id: "test-client",
        clean_session: true,
        keep_alive: 60,
        username: "user",
        password: "pass"
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.username == "user"
      assert decoded.password == "pass"
    end
  end

  describe "CONNACK packet" do
    test "encodes and decodes CONNACK" do
      packet = %{
        type: :connack,
        session_present: false,
        reason_code: 0
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :connack
      assert decoded.session_present == false
      assert decoded.reason_code == 0
    end

    test "encodes CONNACK with session_present true" do
      packet = %{
        type: :connack,
        session_present: true,
        reason_code: 0
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.session_present == true
    end
  end

  describe "PUBLISH packet" do
    test "encodes and decodes QoS 0 PUBLISH" do
      packet = %{
        type: :publish,
        topic: "test/topic",
        payload: "hello world",
        qos: 0,
        retain: false,
        dup: false
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :publish
      assert decoded.topic == ["test", "topic"]
      assert decoded.payload == "hello world"
      assert decoded.qos == 0
      assert decoded.retain == false
    end

    test "encodes and decodes QoS 1 PUBLISH with packet_id" do
      packet = %{
        type: :publish,
        topic: "test/topic",
        payload: "hello",
        qos: 1,
        packet_id: 1234,
        retain: false,
        dup: false
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.qos == 1
      assert decoded.packet_id == 1234
    end

    test "encodes PUBLISH with retain flag" do
      packet = %{
        type: :publish,
        topic: "test",
        payload: "retained",
        qos: 0,
        retain: true,
        dup: false
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.retain == true
    end

    test "encodes PUBLISH with dup flag" do
      packet = %{
        type: :publish,
        topic: "test",
        payload: "",
        qos: 1,
        packet_id: 1,
        retain: false,
        dup: true
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.dup == true
    end

    test "encodes PUBLISH with binary payload" do
      payload = <<0, 1, 2, 3, 255, 254, 253>>

      packet = %{
        type: :publish,
        topic: "binary",
        payload: payload,
        qos: 0,
        retain: false
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.payload == payload
    end
  end

  describe "PUBACK packet" do
    test "encodes and decodes PUBACK" do
      packet = %{
        type: :puback,
        packet_id: 5678
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :puback
      assert decoded.packet_id == 5678
    end
  end

  describe "SUBSCRIBE packet" do
    test "encodes and decodes SUBSCRIBE with single topic" do
      packet = %{
        type: :subscribe,
        packet_id: 100,
        topics: [%{topic: "test/topic", qos: 1}]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :subscribe
      assert decoded.packet_id == 100
      assert length(decoded.topics) == 1
      assert hd(decoded.topics).qos == 1
    end

    test "encodes SUBSCRIBE with multiple topics" do
      packet = %{
        type: :subscribe,
        packet_id: 100,
        topics: [
          %{topic: "topic/a", qos: 0},
          %{topic: "topic/b", qos: 1},
          %{topic: "topic/c", qos: 2}
        ]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert length(decoded.topics) == 3
    end

    test "encodes SUBSCRIBE with wildcard topics" do
      packet = %{
        type: :subscribe,
        packet_id: 100,
        topics: [
          %{topic: "sensors/+/temp", qos: 1},
          %{topic: "devices/#", qos: 0}
        ]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert length(decoded.topics) == 2
      [t1, t2] = decoded.topics
      assert t1.topic == ["sensors", :single_level, "temp"]
      assert t2.topic == ["devices", :multi_level]
    end
  end

  describe "SUBACK packet" do
    test "encodes and decodes SUBACK" do
      packet = %{
        type: :suback,
        packet_id: 100,
        acks: [{:ok, 0}, {:ok, 1}, {:ok, 2}]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :suback
      assert decoded.packet_id == 100
      assert decoded.acks == [{:ok, 0}, {:ok, 1}, {:ok, 2}]
    end

    test "encodes SUBACK with failure" do
      packet = %{
        type: :suback,
        packet_id: 100,
        acks: [{:ok, 0}, {:error, 0x80}]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.acks == [{:ok, 0}, {:error, 0x80}]
    end
  end

  describe "UNSUBSCRIBE packet" do
    test "encodes and decodes UNSUBSCRIBE" do
      packet = %{
        type: :unsubscribe,
        packet_id: 200,
        topics: ["topic/a", "topic/b"]
      }

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :unsubscribe
      assert decoded.packet_id == 200
      assert length(decoded.topics) == 2
    end
  end

  describe "PINGREQ and PINGRESP packets" do
    test "encodes and decodes PINGREQ" do
      packet = %{type: :pingreq}

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :pingreq
      assert encoded == <<0xC0, 0x00>>
    end

    test "encodes and decodes PINGRESP" do
      packet = %{type: :pingresp}

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :pingresp
      assert encoded == <<0xD0, 0x00>>
    end
  end

  describe "DISCONNECT packet" do
    test "encodes and decodes DISCONNECT" do
      packet = %{type: :disconnect}

      {:ok, encoded} = Codec.encode(4, packet)
      {:ok, {decoded, <<>>}} = Codec.decode(4, encoded)

      assert decoded.type == :disconnect
      assert encoded == <<0xE0, 0x00>>
    end
  end

  describe "incomplete data handling" do
    test "returns error for incomplete packet" do
      assert {:error, :incomplete} = Codec.decode(4, <<>>)
      assert {:error, :incomplete} = Codec.decode(4, <<0x30>>)
      assert {:error, :incomplete} = Codec.decode(4, <<0x30, 0x05>>)
    end

    test "returns rest of data after decoding" do
      packet = %{type: :pingreq}
      {:ok, encoded} = Codec.encode(4, packet)

      # Add trailing data
      data_with_extra = encoded <> "extra data"
      {:ok, {decoded, rest}} = Codec.decode(4, data_with_extra)

      assert decoded.type == :pingreq
      assert rest == "extra data"
    end
  end

  describe "iodata encoding" do
    test "encode_iodata returns iodata" do
      packet = %{
        type: :publish,
        topic: "test",
        payload: "hello",
        qos: 0,
        retain: false
      }

      {:ok, iodata} = Codec.encode_iodata(4, packet)
      assert is_list(iodata)

      # Should be equivalent to encode
      {:ok, binary} = Codec.encode(4, packet)
      assert IO.iodata_to_binary(iodata) == binary
    end
  end
end
