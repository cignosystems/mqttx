defmodule MqttX.Packet.PropertiesTest do
  use ExUnit.Case, async: true

  alias MqttX.Packet.Properties

  describe "encode/2 for MQTT 5.0" do
    test "encodes empty properties" do
      result = Properties.encode(5, %{})
      assert IO.iodata_to_binary(result) == <<0>>
    end

    test "encodes payload_format_indicator" do
      result = Properties.encode(5, %{payload_format_indicator: true})
      binary = IO.iodata_to_binary(result)
      assert <<2, 0x01, 1>> = binary

      result = Properties.encode(5, %{payload_format_indicator: false})
      binary = IO.iodata_to_binary(result)
      assert <<2, 0x01, 0>> = binary
    end

    test "encodes message_expiry_interval" do
      result = Properties.encode(5, %{message_expiry_interval: 3600})
      binary = IO.iodata_to_binary(result)
      assert <<5, 0x02, 0, 0, 14, 16>> = binary
    end

    test "encodes content_type" do
      result = Properties.encode(5, %{content_type: "application/json"})
      binary = IO.iodata_to_binary(result)
      # Length prefix + property id + string length + string
      assert byte_size(binary) == 1 + 1 + 2 + 16
    end

    test "encodes response_topic" do
      result = Properties.encode(5, %{response_topic: "reply/topic"})
      binary = IO.iodata_to_binary(result)
      assert byte_size(binary) > 0
    end

    test "encodes correlation_data" do
      result = Properties.encode(5, %{correlation_data: <<1, 2, 3, 4>>})
      binary = IO.iodata_to_binary(result)
      assert byte_size(binary) > 0
    end

    test "encodes session_expiry_interval" do
      result = Properties.encode(5, %{session_expiry_interval: 7200})
      binary = IO.iodata_to_binary(result)
      assert <<5, 0x11, 0, 0, 28, 32>> = binary
    end

    test "encodes receive_maximum" do
      result = Properties.encode(5, %{receive_maximum: 100})
      binary = IO.iodata_to_binary(result)
      assert <<3, 0x21, 0, 100>> = binary
    end

    test "encodes topic_alias_maximum" do
      result = Properties.encode(5, %{topic_alias_maximum: 10})
      binary = IO.iodata_to_binary(result)
      assert <<3, 0x22, 0, 10>> = binary
    end

    test "encodes topic_alias" do
      result = Properties.encode(5, %{topic_alias: 5})
      binary = IO.iodata_to_binary(result)
      assert <<3, 0x23, 0, 5>> = binary
    end

    test "encodes maximum_qos" do
      result = Properties.encode(5, %{maximum_qos: 1})
      binary = IO.iodata_to_binary(result)
      assert <<2, 0x24, 1>> = binary
    end

    test "encodes retain_available" do
      result = Properties.encode(5, %{retain_available: true})
      binary = IO.iodata_to_binary(result)
      assert <<2, 0x25, 1>> = binary
    end

    test "encodes maximum_packet_size" do
      result = Properties.encode(5, %{maximum_packet_size: 65536})
      binary = IO.iodata_to_binary(result)
      assert <<5, 0x27, 0, 1, 0, 0>> = binary
    end

    test "encodes user property" do
      result = Properties.encode(5, %{"custom-key" => "custom-value"})
      binary = IO.iodata_to_binary(result)
      assert byte_size(binary) > 0
    end

    test "encodes multiple properties" do
      props = %{
        payload_format_indicator: true,
        message_expiry_interval: 3600,
        content_type: "text/plain"
      }

      result = Properties.encode(5, props)
      binary = IO.iodata_to_binary(result)
      assert byte_size(binary) > 10
    end
  end

  describe "encode/2 for non-MQTT 5.0" do
    test "returns empty for MQTT 3.1.1" do
      result = Properties.encode(4, %{payload_format_indicator: true})
      assert IO.iodata_to_binary(result) == <<>>
    end

    test "returns empty for MQTT 3.1" do
      result = Properties.encode(3, %{payload_format_indicator: true})
      assert IO.iodata_to_binary(result) == <<>>
    end
  end

  describe "decode/2 for MQTT 5.0" do
    test "decodes empty properties" do
      {:ok, props, rest} = Properties.decode(5, <<0, "remaining">>)
      assert props == %{}
      assert rest == "remaining"
    end

    test "decodes payload_format_indicator" do
      # Length 2, property id 0x01, value 1
      {:ok, props, <<>>} = Properties.decode(5, <<2, 0x01, 1>>)
      assert props.payload_format_indicator == true

      {:ok, props, <<>>} = Properties.decode(5, <<2, 0x01, 0>>)
      assert props.payload_format_indicator == false
    end

    test "decodes message_expiry_interval" do
      {:ok, props, <<>>} = Properties.decode(5, <<5, 0x02, 0, 0, 14, 16>>)
      assert props.message_expiry_interval == 3600
    end

    test "decodes session_expiry_interval" do
      {:ok, props, <<>>} = Properties.decode(5, <<5, 0x11, 0, 0, 28, 32>>)
      assert props.session_expiry_interval == 7200
    end

    test "decodes receive_maximum" do
      {:ok, props, <<>>} = Properties.decode(5, <<3, 0x21, 0, 100>>)
      assert props.receive_maximum == 100
    end

    test "decodes topic_alias_maximum" do
      {:ok, props, <<>>} = Properties.decode(5, <<3, 0x22, 0, 10>>)
      assert props.topic_alias_maximum == 10
    end

    test "decodes topic_alias" do
      {:ok, props, <<>>} = Properties.decode(5, <<3, 0x23, 0, 5>>)
      assert props.topic_alias == 5
    end

    test "decodes maximum_qos" do
      {:ok, props, <<>>} = Properties.decode(5, <<2, 0x24, 1>>)
      assert props.maximum_qos == 1
    end

    test "decodes retain_available" do
      {:ok, props, <<>>} = Properties.decode(5, <<2, 0x25, 1>>)
      assert props.retain_available == true
    end

    test "decodes maximum_packet_size" do
      {:ok, props, <<>>} = Properties.decode(5, <<5, 0x27, 0, 1, 0, 0>>)
      assert props.maximum_packet_size == 65536
    end

    test "decodes content_type" do
      content_type = "application/json"
      len = byte_size(content_type)
      props_len = 1 + 2 + len
      data = <<props_len, 0x03, len::16-big, content_type::binary>>

      {:ok, props, <<>>} = Properties.decode(5, data)
      assert props.content_type == "application/json"
    end

    test "decodes reason_string" do
      reason = "test reason"
      len = byte_size(reason)
      props_len = 1 + 2 + len
      data = <<props_len, 0x1F, len::16-big, reason::binary>>

      {:ok, props, <<>>} = Properties.decode(5, data)
      assert props.reason_string == "test reason"
    end

    test "returns rest of data after decoding" do
      {:ok, props, rest} = Properties.decode(5, <<2, 0x01, 1, "extra data">>)
      assert props.payload_format_indicator == true
      assert rest == "extra data"
    end

    test "returns error for incomplete data" do
      assert {:error, :incomplete} = Properties.decode(5, <<5, 0x02, 0, 0>>)
    end
  end

  describe "decode/2 for non-MQTT 5.0" do
    test "returns empty map and passes through data for MQTT 3.1.1" do
      {:ok, props, rest} = Properties.decode(4, "some data")
      assert props == %{}
      assert rest == "some data"
    end

    test "returns empty map and passes through data for MQTT 3.1" do
      {:ok, props, rest} = Properties.decode(3, "some data")
      assert props == %{}
      assert rest == "some data"
    end
  end

  describe "roundtrip encode/decode" do
    test "roundtrips single properties" do
      props = %{payload_format_indicator: true}
      encoded = Properties.encode(5, props) |> IO.iodata_to_binary()
      {:ok, decoded, <<>>} = Properties.decode(5, encoded)
      assert decoded == props
    end

    test "roundtrips integer properties" do
      props = %{message_expiry_interval: 3600}
      encoded = Properties.encode(5, props) |> IO.iodata_to_binary()
      {:ok, decoded, <<>>} = Properties.decode(5, encoded)
      assert decoded == props
    end

    test "roundtrips string properties" do
      props = %{content_type: "application/json"}
      encoded = Properties.encode(5, props) |> IO.iodata_to_binary()
      {:ok, decoded, <<>>} = Properties.decode(5, encoded)
      assert decoded == props
    end
  end
end
