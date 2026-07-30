defmodule MqttX.PacketTest do
  @moduledoc """
  Exercises the `MqttX.Packet` façade.

  The delegates are trivial, but this module is the documented entry point for
  codec-only users — coverage showed nothing executed it, so a broken delegate
  (or a Codec rename) would have shipped silently.
  """
  use ExUnit.Case, async: true

  @publish %{
    type: :publish,
    topic: "test/topic",
    payload: "hello",
    qos: 0,
    retain: false,
    dup: false,
    properties: %{}
  }

  test "encode/2 and decode/2 round-trip a PUBLISH for every protocol version" do
    for version <- [3, 4, 5] do
      assert {:ok, binary} = MqttX.Packet.encode(version, @publish)
      assert is_binary(binary)
      assert {:ok, {decoded, ""}} = MqttX.Packet.decode(version, binary)
      assert decoded.type == :publish
      assert decoded.topic == ["test", "topic"]
      assert decoded.payload == "hello"
    end
  end

  test "encode_iodata/2 produces iodata equivalent to encode/2" do
    assert {:ok, binary} = MqttX.Packet.encode(4, @publish)
    assert {:ok, iodata} = MqttX.Packet.encode_iodata(4, @publish)
    assert IO.iodata_to_binary(iodata) == binary
  end

  test "declared_length/1 reports the full size of a buffered packet" do
    {:ok, binary} = MqttX.Packet.encode(4, @publish)
    assert {:ok, len} = MqttX.Packet.declared_length(binary)
    assert len == byte_size(binary)
  end

  test "decode/2 returns leftover bytes after a complete packet" do
    {:ok, binary} = MqttX.Packet.encode(4, @publish)
    assert {:ok, {_decoded, <<0xFF>>}} = MqttX.Packet.decode(4, binary <> <<0xFF>>)
  end

  test "the moduledoc example works as written" do
    packet = %{
      type: :publish,
      topic: "test",
      payload: "hello",
      qos: 0,
      retain: false,
      dup: false,
      properties: %{}
    }

    assert {:ok, binary} = MqttX.Packet.encode(4, packet)
    assert {:ok, {_decoded, _rest}} = MqttX.Packet.decode(4, binary)
  end
end
