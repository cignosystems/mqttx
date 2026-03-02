defmodule MqttX.Payload.PayloadTest do
  use ExUnit.Case, async: true

  describe "MqttX.Payload behaviour" do
    test "encode dispatches to codec" do
      assert {:ok, "hello"} = MqttX.Payload.encode(MqttX.Payload.Raw, "hello")
    end

    test "decode dispatches to codec" do
      assert {:ok, "hello"} = MqttX.Payload.decode(MqttX.Payload.Raw, "hello")
    end
  end

  describe "MqttX.Payload.Raw" do
    test "encode returns binary as-is" do
      assert {:ok, "hello"} = MqttX.Payload.Raw.encode("hello")
    end

    test "encode binary payload" do
      binary = <<0, 1, 2, 255>>
      assert {:ok, ^binary} = MqttX.Payload.Raw.encode(binary)
    end

    test "encode empty binary" do
      assert {:ok, ""} = MqttX.Payload.Raw.encode("")
    end

    test "encode rejects non-binary" do
      assert {:error, {:not_binary, 123}} = MqttX.Payload.Raw.encode(123)
      assert {:error, {:not_binary, :atom}} = MqttX.Payload.Raw.encode(:atom)
    end

    test "decode returns binary as-is" do
      assert {:ok, "hello"} = MqttX.Payload.Raw.decode("hello")
    end

    test "decode empty binary" do
      assert {:ok, ""} = MqttX.Payload.Raw.decode("")
    end
  end

  describe "MqttX.Payload.JSON" do
    @describetag :json

    test "encode map to JSON" do
      assert {:ok, json} = MqttX.Payload.JSON.encode(%{"key" => "value"})
      assert {:ok, decoded} = MqttX.Payload.JSON.decode(json)
      assert decoded == %{"key" => "value"}
    end

    test "encode list" do
      assert {:ok, json} = MqttX.Payload.JSON.encode([1, 2, 3])
      assert {:ok, [1, 2, 3]} = MqttX.Payload.JSON.decode(json)
    end

    test "encode nested structure" do
      data = %{"sensor" => %{"temp" => 25.5, "tags" => ["indoor", "floor1"]}}
      assert {:ok, json} = MqttX.Payload.JSON.encode(data)
      assert {:ok, ^data} = MqttX.Payload.JSON.decode(json)
    end

    test "decode invalid JSON returns error" do
      assert {:error, {:json_decode_error, _}} = MqttX.Payload.JSON.decode("not json{")
    end

    test "roundtrip with string value" do
      assert {:ok, json} = MqttX.Payload.JSON.encode("hello")
      assert {:ok, "hello"} = MqttX.Payload.JSON.decode(json)
    end

    test "roundtrip with integer" do
      assert {:ok, json} = MqttX.Payload.JSON.encode(42)
      assert {:ok, 42} = MqttX.Payload.JSON.decode(json)
    end

    test "roundtrip with boolean" do
      assert {:ok, json} = MqttX.Payload.JSON.encode(true)
      assert {:ok, true} = MqttX.Payload.JSON.decode(json)
    end

    test "roundtrip with null" do
      assert {:ok, json} = MqttX.Payload.JSON.encode(nil)
      assert {:ok, nil} = MqttX.Payload.JSON.decode(json)
    end
  end

  describe "MqttX.Payload.Protobuf" do
    test "encode non-struct returns error" do
      assert {:error, :invalid_protobuf_term} = MqttX.Payload.Protobuf.encode("not a struct")
    end

    test "decode without message type returns error" do
      assert {:error, :message_type_required} = MqttX.Payload.Protobuf.decode(<<1, 2, 3>>)
    end

    test "encode with unknown module tuple returns error" do
      result = MqttX.Payload.Protobuf.encode({NonExistentModule, %{field: "value"}})
      assert {:error, {:unknown_message_module, NonExistentModule}} = result
    end

    test "encode non-protobuf struct returns error" do
      result = MqttX.Payload.Protobuf.encode(%URI{host: "test"})
      assert {:error, {:protobuf_encode_error, _}} = result
    end

    test "encode_iodata non-protobuf struct returns error" do
      result = MqttX.Payload.Protobuf.encode_iodata(%URI{host: "test"})
      assert {:error, {:protobuf_encode_error, _}} = result
    end
  end
end
