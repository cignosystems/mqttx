<p align="center">
  <img src="https://raw.githubusercontent.com/cignosystems/mqttx/main/assets/mqttx.png" alt="MqttX" width="600">
</p>

<p align="center">
  <a href="https://hex.pm/packages/mqttx"><img src="https://img.shields.io/hexpm/v/mqttx.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/mqttx"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Docs"></a>
  <a href="https://github.com/cignosystems/mqttx/actions/workflows/ci.yml"><img src="https://github.com/cignosystems/mqttx/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

# MqttX

Fast, pure Elixir MQTT 5.0 — client, server, and codec in one package.

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

### MQTT vs WebSocket (Same JSON Payload)

Even when using JSON for both protocols, MQTT still provides significant overhead savings:

| Metric | WebSocket + JSON | MQTT + JSON | Savings |
|--------|------------------|-------------|---------|
| Connection handshake | ~300-500 bytes | ~30-50 bytes | **90%** |
| Per-message overhead | 6-14 bytes | 2-4 bytes | **70%** |
| Keep-alive (ping) | ~6 bytes | 2 bytes | **67%** |
| 52-byte JSON message | 58-66 bytes total | 54-56 bytes total | **15-18%** |

**Key insight**: MQTT's binary protocol has lower framing overhead than WebSocket's text-based frames. For high-frequency IoT messages, this adds up significantly.

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
    {:mqttx, "~> 0.7.1"},
    # Optional: Pick a transport
    {:thousand_island, "~> 1.4"},  # or {:ranch, "~> 2.2"}
    # Optional: WebSocket transport
    {:bandit, "~> 1.6"},
    {:websock_adapter, "~> 0.5"},
    # Optional: Payload codecs
    {:protox, "~> 2.0"}
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
# Connect with TCP (default)
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

### TLS/SSL Connection

```elixir
# Connect with TLS
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,                    # default SSL port
  client_id: "secure_client",
  transport: :ssl,
  ssl_opts: [
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    server_name_indication: ~c"broker.example.com"
  ]
)
```

### Session Persistence

```elixir
# Enable session persistence for QoS 1/2 message reliability
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  client_id: "persistent_client",
  clean_session: false,          # maintain session across reconnects
  session_store: MqttX.Session.ETSStore  # built-in ETS store
)
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

### WebSocket

```elixir
MqttX.Server.start_link(
  MyHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8083
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

### Compliance

Fully compliant with MQTT 3.1, 3.1.1, and 5.0 specifications:

- **Server**: CONNACK capability properties, protocol ordering enforcement, topic alias validation, MQTT 5.0 property forwarding, subscription options (no_local, retain_handling)
- **Client**: server_keep_alive override, assigned_client_identifier, maximum_packet_size enforcement, server_reference handling, enhanced AUTH (multi-step), flow control (receive_maximum)

Validated against Mosquitto (104 automated protocol tests across TCP and WebSocket) and EMQX Cloud (49 interop tests covering all QoS levels, properties, session persistence, and subscription options).

## Performance

Architected to scale from tens of thousands to **hundreds of thousands of concurrent devices** on a single BEAM node, depending on hardware and workload. Each connection is a lightweight Erlang process (~20KB total with connection state and socket), and the hot paths are optimized for high message throughput:

- **Trie-based topic router**: O(L+K) matching where L = topic depth, K = matching subscriptions — independent of total subscription count
- **iodata encoding**: Socket sends use iodata directly, avoiding binary copies on every packet
- **Zero-copy binary references**: Decoder returns sub-binaries for payload and topic
- **Empty-buffer fast path**: Skips binary concatenation when the TCP buffer is empty (common case)
- **Cached callback dispatch**: `function_exported?` computed once at connection init, not per message
- **Direct inflight counter**: O(1) flow control check instead of scanning pending_acks
- **ETS-optimized retained delivery**: O(1) lookup for exact topic subscriptions

| Metric | Conservative | Optimistic |
|--------|-------------|------------|
| Concurrent connections | 50,000 | 200,000 |
| Messages/second (QoS 0) | 100,000 | 500,000+ |
| Messages/second (QoS 1) | 50,000 | 200,000 |
| Memory per connection | ~20 KB | ~20 KB |

**Codec benchmarks vs mqtt_packet_map** (Apple M4 Pro):

| Operation | MqttX | mqtt_packet_map | Result |
|-----------|-------|-----------------|--------|
| PUBLISH encode | 5.05M ips | 1.72M ips | **2.9x faster** |
| SUBSCRIBE encode | 3.42M ips | 0.82M ips | **4.2x faster** |
| PUBLISH decode | 2.36M ips | 2.25M ips | ~same |

See the [Performance & Scaling guide](guides/performance.md) for VM tuning, OS tuning, and deployment recommendations.

## API Reference

### MqttX.Client

| Function | Description |
|----------|-------------|
| `connect(opts)` | Connect to an MQTT broker |
| `connect_supervised(opts)` | Connect under `MqttX.Client.Supervisor` with crash recovery |
| `list()` | List all registered client connections |
| `whereis(client_id)` | Look up a connection by client_id |
| `publish(client, topic, payload, opts \\ [])` | Publish a message. Options: `:qos` (0-2), `:retain` (boolean) |
| `subscribe(client, topics, opts \\ [])` | Subscribe to topics. Options: `:qos` (0-2) |
| `unsubscribe(client, topics)` | Unsubscribe from topics |
| `disconnect(client)` | Disconnect from the broker |
| `connected?(client)` | Check if client is connected |

**Connect Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `:host` | Broker hostname (required) | - |
| `:port` | Broker port | 1883 (TCP), 8883 (SSL) |
| `:client_id` | Client identifier (required) | - |
| `:username` | Authentication username | `nil` |
| `:password` | Authentication password | `nil` |
| `:clean_session` | Start fresh session | `true` |
| `:keepalive` | Keep-alive interval (seconds) | 60 |
| `:transport` | `:tcp` or `:ssl` | `:tcp` |
| `:ssl_opts` | SSL options for `:ssl` transport | `[]` |
| `:retry_interval` | QoS retry interval (ms) | 5000 |
| `:max_inflight` | Max pending QoS 1/2 messages | 100 |
| `:connect_properties` | MQTT 5.0 CONNECT properties (e.g. `%{session_expiry_interval: 3600}`) | `%{}` |
| `:session_store` | Session store module | `nil` |
| `:handler` | Callback module for messages | `nil` |
| `:handler_state` | Initial handler state | `nil` |

### MqttX.Server

| Function | Description |
|----------|-------------|
| `start_link(handler, handler_opts, opts)` | Start an MQTT server. Options: `:transport`, `:port`, `:name`, `:rate_limit` |

**Callbacks:**

| Callback | Description |
|----------|-------------|
| `init(opts)` | Initialize handler state |
| `handle_connect(client_id, credentials, state)` | Handle client connection. Return `{:ok, state}` or `{:error, reason_code, state}` |
| `handle_publish(topic, payload, opts, state)` | Handle incoming PUBLISH. Return `{:ok, state}` |
| `handle_subscribe(topics, state)` | Handle SUBSCRIBE. Return `{:ok, granted_qos_list, state}` |
| `handle_unsubscribe(topics, state)` | Handle UNSUBSCRIBE. Return `{:ok, state}` |
| `handle_disconnect(reason, state)` | Handle client disconnection. Return `:ok` |
| `handle_info(message, state)` | Handle custom messages. Return `{:ok, state}`, `{:publish, topic, payload, state}`, or `{:stop, reason, state}` |

### MqttX.Packet.Codec

| Function | Description |
|----------|-------------|
| `encode(version, packet)` | Encode a packet to binary. Returns `{:ok, binary}` |
| `decode(version, binary)` | Decode a packet from binary. Returns `{:ok, {packet, rest}}` or `{:error, reason}` |
| `encode_iodata(version, packet)` | Encode to iodata (more efficient). Returns `{:ok, iodata}` |

### MqttX.Server.Router

| Function | Description |
|----------|-------------|
| `new()` | Create a new empty router |
| `subscribe(router, filter, client, opts)` | Add a subscription. Options: `:qos` |
| `unsubscribe(router, filter, client)` | Remove a subscription |
| `unsubscribe_all(router, client)` | Remove all subscriptions for a client |
| `match(router, topic)` | Find matching subscriptions. Returns `[{client, opts}]` |

### MqttX.Topic

| Function | Description |
|----------|-------------|
| `validate(topic)` | Validate and normalize a topic. Returns `{:ok, normalized}` or `{:error, :invalid_topic}` |
| `validate_publish(topic)` | Validate topic for publishing (no wildcards) |
| `matches?(filter, topic)` | Check if a filter matches a topic |
| `normalize(topic)` | Normalize topic to list format |
| `flatten(normalized)` | Convert normalized topic back to binary string |
| `wildcard?(topic)` | Check if topic contains wildcards |

## Roadmap

| Feature | Status | Description |
|---------|--------|-------------|
| **Full MQTT 5.0 Compliance** | Done | Complete server and client compliance — all CONNACK properties, enhanced AUTH, flow control, server redirect |
| **WebSocket Transport** | Done | MQTT over WebSocket via Bandit (`ws://` and `wss://`) |
| **Broker Validation** | Done | 104 Mosquitto tests (TCP + WebSocket) + 49 EMQX Cloud interop tests |
| **Clustering** | Planned | Distributed router across Erlang nodes via `pg` |
| **Property-based Tests** | Planned | StreamData for fuzzing the packet codec |
| **End-to-end Load Tests** | Planned | Benchee-based throughput validation under realistic workloads |

## License

Apache-2.0