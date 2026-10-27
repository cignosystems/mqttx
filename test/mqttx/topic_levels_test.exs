defmodule MqttX.TopicLevelsTest do
  @moduledoc """
  A topic or filter has at most `MqttX.Topic.max_levels/0` levels: the
  subscription index is walked level by level, so a topic of tens of
  thousands of levels would cost that much on every publish, on every node.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Packet.Varint
  alias MqttX.Topic

  defp levels(n), do: Enum.map_join(1..n, "/", &"l#{&1}")

  test "the deepest allowed topic and one level more" do
    max = Topic.max_levels()
    assert max == 128

    assert {:ok, _} = Topic.validate(levels(max))
    assert {:ok, _} = Topic.validate_publish(levels(max))
    assert {:ok, _} = Topic.validate(levels(max - 1) <> "/#")

    assert {:error, :invalid_topic} = Topic.validate(levels(max + 1))
    assert {:error, :invalid_topic} = Topic.validate_publish(levels(max + 1))
    assert {:error, :invalid_topic} = Topic.validate(List.duplicate("l", max + 1))
  end

  test "empty levels count: a filter of slashes alone is capped too" do
    assert {:error, :invalid_topic} = Topic.validate(String.duplicate("/", 200))
  end

  test "a PUBLISH or SUBSCRIBE carrying a deeper topic does not decode" do
    deep = levels(Topic.max_levels() + 1)

    # On the wire, past the encoder's own check: a v5 PUBLISH (topic, no
    # properties, payload "x") and a v5 SUBSCRIBE (packet id 1, no
    # properties, one filter, options 0)
    publish_body = <<byte_size(deep)::16, deep::binary, 0, "x">>
    publish = <<0x30, Varint.encode(byte_size(publish_body))::binary, publish_body::binary>>
    assert {:error, :invalid_topic} = Codec.decode(5, publish)

    sub_body = <<1::16, 0, byte_size(deep)::16, deep::binary, 0>>
    subscribe = <<0x82, Varint.encode(byte_size(sub_body))::binary, sub_body::binary>>
    assert {:error, :invalid_topic} = Codec.decode(5, subscribe)
  end
end
