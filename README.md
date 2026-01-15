# MqttX

[![Hex.pm](https://img.shields.io/hexpm/v/mqttx.svg)](https://hex.pm/packages/mqttx)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/mqttx)
[![CI](https://github.com/cignosystems/mqttx/actions/workflows/ci.yml/badge.svg)](https://github.com/cignosystems/mqttx/actions/workflows/ci.yml)

A pure Elixir MQTT 3.1.1/5.0 library featuring:

- 🚀 High-performance packet codec
- 🖥️ Transport-agnostic server/broker
- 📡 Modern client with automatic reconnection
- 🔌 Pluggable transports (ThousandIsland, Ranch)
- 📦 Optional payload codecs (JSON, Protobuf)

## MQTT for Cellular IoT

For IoT devices on cellular networks (LTE-M, NB-IoT), every byte matters. Data transmission costs money, drains batteries, and increases latency. MQTT combined with Protobuf dramatically outperforms WebSocket with JSON:

### Protocol Overhead Comparison

| Metric | WebSocket + JSON | MQTT + Protobuf | Savings |
|--------|------------------|-----------------|---------|
| Connection handshake | ~300-500 bytes | ~30-50 bytes | **90%** |
| Per-message overhead | 6-14 bytes | 2-4 bytes | **70%** |
| Keep-alive (ping) | ~6 bytes | 2 bytes | **67%** |

### Real-World Payload Example

Sending a sensor reading `{temperature: 25.5, humidity: 60, battery: 85}`:

| Format | Size | Notes |
|--------|------|-------|
| JSON | 52 bytes | `{"temperature":25.5,"humidity":60,"battery":85}` |
| Protobuf | 9 bytes | Binary: `0x08 0xCC 0x01 0x10 0x3C 0x18 0x55` |
| **Reduction** | **83%** | 5.8x smaller |

### Monthly Data Usage (1 device, 1 msg/min)

| Protocol | Payload | Monthly Data |
|----------|---------|--------------|
| WebSocket + JSON | 52 bytes | ~2.2 MB |
| MQTT + Protobuf | 9 bytes | ~0.4 MB |
| **Savings** | | **1.8 MB/device** |

For fleets of thousands of devices, this translates to significant cost savings on cellular data plans and extended battery life from reduced radio-on time.

## Why MqttX?

Existing Elixir/Erlang MQTT libraries have limitations:

- **mqtt_packet_map**: Erlang-only codec, no server/client, slower encoding
- **Tortoise/Tortoise311**: Client-only, complex supervision, dated architecture
- **emqtt**: Erlang-focused, heavy dependencies

MqttX provides a **unified, pure Elixir solution** with:

- **2.9-4.2x faster encoding** than mqtt_packet_map for common packets
- Modern GenServer-based client with exponential backoff reconnection
- Transport-agnostic server that works with ThousandIsland or Ranch
- Clean, composable API designed for IoT and real-time applications
- Zero external dependencies for the core codec

The codec has been tested for interoperability with:

- **Zephyr RTOS** MQTT client (Nordic nRF9160, nRF52)
- **Eclipse Paho** clients (C, Python, JavaScript)
- **Mosquitto** broker
- Standard MQTT test suites

## Installation

Add `mqttx` to your dependencies:

```elixir
def deps do
  [
    {:mqttx, "~> 0.1.0"},
    # Optional: Pick a transport
    {:thousand_island, "~> 1.0"},  # or {:ranch, "~> 2.1"}
    # Optional: Payload codecs
    {:protox, "~> 1.7"}
  ]
end
```

## Quick Start

### MQTT Server

Create a handler module:

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  @impl true
  def init(_opts) do
    %{subscriptions: %{}}
  end

  @impl true
  def handle_connect(client_id, credentials, state) do
    IO.puts("Client connected: #{client_id}")
    {:ok, state}
  end

  @impl true
  def handle_publish(topic, payload, opts, state) do
    IO.puts("Received on #{inspect(topic)}: #{payload}")
    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state) do
    qos_list = Enum.map(topics, fn t -> t.qos end)
    {:ok, qos_list, state}
  end

  @impl true
  def handle_disconnect(reason, _state) do
    IO.puts("Client disconnected: #{inspect(reason)}")
    :ok
  end
end
```

Start the server:

```elixir
{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

### MQTT Client

```elixir
# Connect
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client",
  username: "user",        # optional
  password: "secret"       # optional
)

# Subscribe
:ok = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

# Publish
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

# Disconnect
:ok = MqttX.Client.disconnect(client)
```

### Packet Codec (Standalone)

```elixir
# Encode a packet
packet = %{
  type: :publish,
  topic: "test/topic",
  payload: "hello",
  qos: 0,
  retain: false
}
{:ok, binary} = MqttX.Packet.Codec.encode(4, packet)

# Decode a packet
{:ok, {decoded, rest}} = MqttX.Packet.Codec.decode(4, binary)
```

## Transport Adapters

MqttX supports pluggable transports:

### ThousandIsland (Recommended)

```elixir
MqttX.Server.start_link(
  MyHandler,
  [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

### Ranch

```elixir
MqttX.Server.start_link(
  MyHandler,
  [],
  transport: MqttX.Transport.Ranch,
  port: 1883
)
```

## Payload Codecs

Built-in payload codecs for message encoding/decoding:

### JSON (Erlang/OTP 27+)

Uses the built-in Erlang JSON module:

```elixir
{:ok, json} = MqttX.Payload.JSON.encode(%{temp: 25.5})
{:ok, data} = MqttX.Payload.JSON.decode(json)
```

### Protobuf

```elixir
{:ok, binary} = MqttX.Payload.Protobuf.encode(my_proto_struct)
{:ok, struct} = MqttX.Payload.Protobuf.decode(binary, MyProto.Message)
```

### Raw (Pass-through)

```elixir
{:ok, binary} = MqttX.Payload.Raw.encode(<<1, 2, 3>>)
{:ok, binary} = MqttX.Payload.Raw.decode(<<1, 2, 3>>)
```

## Topic Routing

The server includes a topic router with wildcard support:

```elixir
alias MqttX.Server.Router

router = Router.new()
router = Router.subscribe(router, "sensors/+/temp", client_ref, qos: 1)
router = Router.subscribe(router, "alerts/#", client_ref, qos: 0)

# Find matching subscriptions
matches = Router.match(router, "sensors/room1/temp")
# => [{client_ref, %{qos: 1}}]
```

## Protocol Support

- MQTT 3.1 (protocol version 3)
- MQTT 3.1.1 (protocol version 4)
- MQTT 5.0 (protocol version 5)

All 15 packet types are supported:
- CONNECT, CONNACK
- PUBLISH, PUBACK, PUBREC, PUBREL, PUBCOMP
- SUBSCRIBE, SUBACK
- UNSUBSCRIBE, UNSUBACK
- PINGREQ, PINGRESP
- DISCONNECT
- AUTH (MQTT 5.0)

## Performance

The packet codec is optimized for:

- Zero-copy binary references (sub-binaries)
- Unrolled remaining length decode for common cases
- Returns iodata for encoding (avoids concatenation)
- Inline functions for hot paths

**Benchmarks vs mqtt_packet_map** (Apple M4 Pro):

| Operation | MqttX | mqtt_packet_map | Result |
|-----------|-------|-----------------|--------|
| PUBLISH encode | 5.05M ips | 1.72M ips | **2.9x faster** |
| SUBSCRIBE encode | 3.42M ips | 0.82M ips | **4.2x faster** |
| PUBLISH decode | 2.36M ips | 2.25M ips | ~same |

## Roadmap

### v0.3.0 - Core Functionality

| Feature | Description | Priority |
|---------|-------------|----------|
| **TLS/SSL Client Support** | Client only supports TCP, no `:ssl` option | High |
| **QoS 2 Complete Flow** | Client doesn't implement PUBREC/PUBREL/PUBCOMP exchange | High |
| **Message Inflight Tracking** | No retry mechanism for unacknowledged QoS 1/2 messages | High |
| **Session Persistence** | `clean_session=false` sessions aren't stored/restored | Medium |
| **Retained Messages** | Server doesn't store or deliver retained messages | Medium |
| **Will Message Delivery** | Server receives will but doesn't publish on ungraceful disconnect | Medium |

### v0.4.0 - MQTT 5.0 Advanced Features

| Feature | Description |
|---------|-------------|
| **Shared Subscriptions** | `$share/group/topic` pattern for load balancing |
| **Topic Alias** | Reduce bandwidth with topic aliases |
| **Message Expiry** | Respect `message_expiry_interval` property |
| **Flow Control** | Enforce `receive_maximum` for backpressure |
| **Enhanced Auth** | Complete AUTH packet exchange flow |
| **Request/Response** | Response topic and correlation data handling |

### v0.5.0 - Production Readiness

| Feature | Description |
|---------|-------------|
| **Telemetry** | `:telemetry` events for metrics/observability |
| **WebSocket Transport** | For browser-based MQTT clients |
| **Clustering** | Distributed router across Erlang nodes |
| **Connection Supervision** | `DynamicSupervisor` for client connections |
| **Rate Limiting** | Connection and message rate limits |

### Future Improvements

| Item | Description |
|------|-------------|
| **Trie-based Router** | O(topic_depth) matching instead of O(n) list scan |
| **Property-based Tests** | StreamData for fuzzing packet codec |
| **Integration Tests** | Test against Mosquitto, EMQX, HiveMQ |

## License

Apache-2.0
