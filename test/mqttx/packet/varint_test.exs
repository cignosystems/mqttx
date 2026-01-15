defmodule MqttX.Packet.VarintTest do
  use ExUnit.Case, async: true

  alias MqttX.Packet.Varint

  describe "encode/1" do
    test "encodes single byte values (0-127)" do
      assert Varint.encode(0) == <<0>>
      assert Varint.encode(1) == <<1>>
      assert Varint.encode(127) == <<127>>
    end

    test "encodes two byte values (128-16383)" do
      assert Varint.encode(128) == <<128, 1>>
      assert Varint.encode(16383) == <<255, 127>>
    end

    test "encodes three byte values (16384-2097151)" do
      assert Varint.encode(16384) == <<128, 128, 1>>
      assert Varint.encode(2_097_151) == <<255, 255, 127>>
    end

    test "encodes four byte values (2097152-268435455)" do
      assert Varint.encode(2_097_152) == <<128, 128, 128, 1>>
      assert Varint.encode(268_435_455) == <<255, 255, 255, 127>>
    end
  end

  describe "decode/1" do
    test "decodes single byte values" do
      assert Varint.decode(<<0, "rest">>) == {:ok, 0, "rest"}
      assert Varint.decode(<<127, "rest">>) == {:ok, 127, "rest"}
    end

    test "decodes two byte values" do
      assert Varint.decode(<<128, 1, "rest">>) == {:ok, 128, "rest"}
      assert Varint.decode(<<255, 127, "rest">>) == {:ok, 16383, "rest"}
    end

    test "decodes three byte values" do
      assert Varint.decode(<<128, 128, 1, "rest">>) == {:ok, 16384, "rest"}
      assert Varint.decode(<<255, 255, 127, "rest">>) == {:ok, 2_097_151, "rest"}
    end

    test "decodes four byte values" do
      assert Varint.decode(<<128, 128, 128, 1, "rest">>) == {:ok, 2_097_152, "rest"}
      assert Varint.decode(<<255, 255, 255, 127, "rest">>) == {:ok, 268_435_455, "rest"}
    end

    test "returns incomplete for truncated data" do
      assert Varint.decode(<<>>) == :incomplete
      assert Varint.decode(<<128>>) == :incomplete
      assert Varint.decode(<<128, 128>>) == :incomplete
      assert Varint.decode(<<128, 128, 128>>) == :incomplete
    end

    test "returns error for overflow (continuation bit on 4th byte)" do
      assert Varint.decode(<<128, 128, 128, 128, 0>>) == {:error, :varint_overflow}
    end
  end

  describe "roundtrip" do
    test "encode and decode are inverse operations" do
      values = [0, 1, 127, 128, 16383, 16384, 2_097_151, 2_097_152, 268_435_455]

      for value <- values do
        encoded = Varint.encode(value)
        {:ok, decoded, <<>>} = Varint.decode(encoded)
        assert decoded == value, "Failed for value #{value}"
      end
    end
  end

  describe "byte_length/1" do
    test "returns correct byte length" do
      assert Varint.byte_length(0) == 1
      assert Varint.byte_length(127) == 1
      assert Varint.byte_length(128) == 2
      assert Varint.byte_length(16383) == 2
      assert Varint.byte_length(16384) == 3
      assert Varint.byte_length(2_097_151) == 3
      assert Varint.byte_length(2_097_152) == 4
      assert Varint.byte_length(268_435_455) == 4
    end
  end

  describe "encode_iodata/1" do
    test "returns equivalent data as encode" do
      values = [0, 127, 128, 16383, 16384, 268_435_455]

      for value <- values do
        iodata = Varint.encode_iodata(value)
        binary = Varint.encode(value)
        assert IO.iodata_to_binary(iodata) == binary
      end
    end
  end
end
