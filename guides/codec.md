# Codec & Payloads

## Packet Codec

The packet codec supports all 15 MQTT packet types across MQTT 3.1, 3.1.1, and 5.0:

```elixir
# Encode a PUBLISH packet (MQTT 3.1.1 = version 4)
packet = %{type: :publish, topic: "test/topic", payload: "hello", qos: 0, retain: false}
{:ok, binary} = MqttX.Packet.Codec.encode(4, packet)

# Decode
{:ok, {decoded, rest}} = MqttX.Packet.Codec.decode(4, binary)

# Encode to iodata (more efficient for socket writes)
{:ok, iodata} = MqttX.Packet.Codec.encode_iodata(4, packet)
```

### Protocol Versions

| Version | Protocol |
|---------|----------|
| `3` | MQTT 3.1 |
| `4` | MQTT 3.1.1 |
| `5` | MQTT 5.0 |

### Supported Packet Types

CONNECT, CONNACK, PUBLISH, PUBACK, PUBREC, PUBREL, PUBCOMP, SUBSCRIBE, SUBACK, UNSUBSCRIBE, UNSUBACK, PINGREQ, PINGRESP, DISCONNECT, AUTH (MQTT 5.0 only).

### Performance

The codec is optimized with zero-copy binary references, unrolled varint decoding, and iodata output to avoid concatenation.

Measured figures, and what they mean for capacity, are in the
[Performance guide](performance.md#packet-encoding).

## Payload Codecs

MqttX includes pluggable payload codecs for encoding/decoding message payloads. All codecs implement the `MqttX.Payload` behaviour.

### JSON (OTP 27+ / Elixir 1.18+)

Uses the built-in Erlang `JSON` module - no external dependencies:

```elixir
{:ok, json} = MqttX.Payload.JSON.encode(%{temp: 25.5, humidity: 60})
{:ok, data} = MqttX.Payload.JSON.decode(json)
```

### Protobuf

Requires the `{:protox, "~> 2.0"}` optional dependency:

```elixir
{:ok, binary} = MqttX.Payload.Protobuf.encode(my_proto_struct)
{:ok, struct} = MqttX.Payload.Protobuf.decode(binary, MyProto.Message)
```

### Raw (Pass-through)

No transformation - binary in, binary out:

```elixir
{:ok, binary} = MqttX.Payload.Raw.encode(<<1, 2, 3>>)
{:ok, binary} = MqttX.Payload.Raw.decode(<<1, 2, 3>>)
```

### Custom Codecs

Implement `MqttX.Payload` for your own formats:

```elixir
defmodule MyApp.MsgPackCodec do
  @behaviour MqttX.Payload

  @impl true
  def encode(term), do: {:ok, Msgpax.pack!(term)}

  @impl true
  def decode(binary), do: {:ok, Msgpax.unpack!(binary)}
end
```

---

← Back to the [documentation index](../README.md#guides)
