defmodule MqttX.Packet do
  @moduledoc """
  Public entry point for the MQTT wire codec.

  A thin façade over `MqttX.Packet.Codec` — use this module when you have
  your own transport and only need packet encoding/decoding.

  ## Example

      packet = %{type: :publish, topic: "test", payload: "hello", qos: 0,
                 retain: false, dup: false, properties: %{}}

      {:ok, binary} = MqttX.Packet.encode(4, packet)
      {:ok, {decoded, rest}} = MqttX.Packet.decode(4, binary)
  """

  alias MqttX.Packet.Codec

  @doc "Encode an MQTT packet map to a binary. See `MqttX.Packet.Codec.encode/2`."
  defdelegate encode(version, packet), to: Codec

  @doc "Encode an MQTT packet map to iodata. See `MqttX.Packet.Codec.encode_iodata/2`."
  defdelegate encode_iodata(version, packet), to: Codec

  @doc "Decode an MQTT packet from a binary. See `MqttX.Packet.Codec.decode/2`."
  defdelegate decode(version, data), to: Codec

  @doc "Declared total size of a buffered packet. See `MqttX.Packet.Codec.declared_length/1`."
  defdelegate declared_length(data), to: Codec
end
