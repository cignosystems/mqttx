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

> **AI coding assistants:** see [`AGENTS.md`](https://hexdocs.pm/mqttx/agents.html)
> for the mental model, idiomatic patterns, and a list of mistakes commonly
> made when integrating MqttX.

> **Name note:** MqttX (this Elixir library) is not affiliated with
> [MQTTX](https://mqttx.app), EMQX's desktop MQTT client tool. The hex package
> name `mqttx` is stable — you can depend on it.

## Installation

Requires **Elixir 1.18+ / OTP 27+** (the JSON payload codec uses the native
`JSON` module; CI covers Elixir 1.18-1.20 on OTP 27-29).

Add `mqttx` to your dependencies:

```elixir
def deps do
  [
    {:mqttx, "~> 0.12.0"},
    # Optional: Pick a transport
    {:thousand_island, "~> 1.4"},  # or {:ranch, "~> 2.2"}
    # Optional: WebSocket transport
    {:bandit, "~> 1.6"},
    {:websock_adapter, "~> 0.5 or ~> 0.6"},
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
  def handle_connect(client_id, credentials, connect_info, state) do
    # credentials:  %{username: String.t(), password: String.t()}
    # connect_info: %{protocol_version: 3 | 4 | 5, keep_alive: non_neg_integer(),
    #                 session_present: boolean(), subscriptions: [map()], ...}
    IO.puts("[MQTT] CONNECT #{client_id} v#{connect_info.protocol_version} keepalive=#{connect_info.keep_alive}")
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
# Connect with TCP (default). connect/1 is asynchronous — `await_connect: true`
# blocks until the session is live so the calls below work inline; long-lived
# clients should instead act on the handler's :connected event.
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client",
  await_connect: true,
  username: "user",        # optional
  password: "secret"       # optional
)

# Subscribe (returns {:ok, granted_qos_list})
{:ok, [1]} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

# Publish
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

# Disconnect
:ok = MqttX.Client.disconnect(client)
```

### TLS/SSL Connection

Certificates are **verified by default** since v0.11.0 — `verify_peer` against
the OS trust store, with SNI and HTTPS-style hostname checking:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,                    # default SSL port
  client_id: "secure_client",
  transport: :ssl
)
```

Options in `:ssl_opts` are merged *over* that baseline — supply a private CA
with `ssl_opts: [cacertfile: "/etc/ssl/private-ca.pem"]`, or, for a
development broker with a self-signed certificate, opt out explicitly with
`ssl_opts: [verify: :verify_none]` (logs a warning on every connect).

### Behind an HTTP proxy

Where direct outbound to 1883/8883 is blocked, tunnel through an HTTP
`CONNECT` proxy — works for every transport, and TLS is still negotiated with
the broker through the tunnel:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,
  client_id: "behind_proxy",
  transport: :ssl,
  proxy: [host: "proxy.corp", port: 3128, auth: {"user", "pass"}]
)
```

### Session Persistence

```elixir
# Enable session persistence for QoS 1/2 message reliability
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  client_id: "persistent_client",
  protocol_version: 5,
  clean_session: false,          # maintain session across reconnects
  connect_properties: %{session_expiry_interval: 3600},  # v5 default is 0 = ends at disconnect
  session_store: MqttX.Session.ETSStore  # built-in ETS store
)
```

The stored record carries `expires_at` from the negotiated Session Expiry
Interval; an expired record is discarded on the next connect and the ETS store
sweeps expired records periodically.

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

## Why MQTT, and why MqttX?

MQTT is the right protocol for constrained and cellular deployments, and
this library exists because the alternatives in the ecosystem each leave a
gap. The reasoning — protocol-overhead comparisons against HTTP and
WebSocket, real payload measurements, monthly cellular data budgets, and an
honest comparison with the other Elixir/Erlang MQTT libraries — lives in
[Why MQTT for IoT](https://hexdocs.pm/mqttx/why-mqtt-for-iot.html).

## Common Patterns

### Receiving messages on the client

Provide a handler module that implements `handle_mqtt_event/3`. The client
calls it on connect, disconnect, for every incoming PUBLISH, and when the
broker rejects one of your QoS 1/2 publishes:

```elixir
defmodule MyApp.MqttClientHandler do
  def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
    IO.puts("Got #{payload} on #{Enum.join(topic, "/")}")
    state
  end

  # Catch-all so other events (:connected, :disconnected, :publish_error)
  # don't raise
  def handle_mqtt_event(_event, _data, state), do: state
end

{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "subscriber",
  handler: MyApp.MqttClientHandler,
  handler_state: %{},
  await_connect: true
)

{:ok, _granted} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)
```

`topic` arrives as a list of segments (`["sensors", "room1", "temp"]`), not the
original string. The full event list, the payload/packet shapes, and the rules
for calling back into the client from a handler are in the
**[Client Guide](https://hexdocs.pm/mqttx/client.html#receiving-messages)**.

### Module-based client (`use MqttX`)

For a client that owns its callbacks, connection, and supervision in one
module:

```elixir
defmodule MyApp.Sensors do
  use MqttX

  @impl true
  def handle_message(topic, payload, _packet, state) do
    # Safe to publish from inside a callback — callbacks run in this module's
    # own process, not inside the connection
    publish("ack/" <> Enum.join(topic, "/"), payload, qos: 1)
    {:ok, state}
  end
end

# In your supervision tree:
children = [{MyApp.Sensors, host: "broker.example.com", client_id: "sensors-1"}]
```

Every callback has a default, so implement only what you need. The full
callback list and the injected helpers are documented in
**`MqttX.SimpleClient`** and the
**[Client Guide](https://hexdocs.pm/mqttx/client.html#module-based-clients-use-mqttx)**.

### Fan-out between clients (`MqttX.Server.deliver/3`)

The broker does its own routing when you ask it to. Authorize the publish in
`handle_publish/4`, then hand it to `deliver/3`: it matches every session's
subscriptions on the listener, applies each subscription's options, sends to
connected clients and queues QoS 1/2 for persistent sessions that are away:

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  def init(_), do: %{client_id: nil}

  def handle_connect(client_id, _creds, _info, state),
    do: {:ok, %{state | client_id: client_id}}

  def handle_publish(topic, payload, opts, state) do
    if MyApp.ACL.may_publish?(state.client_id, topic) do
      MqttX.Server.deliver(topic, payload, Map.put(opts, :publisher, state.client_id))
      {:ok, state}
    else
      {:error, :unauthorized, state}
    end
  end

  def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
  def handle_disconnect(_reason, _state), do: :ok
end

# From anywhere in your app, by the listener's :name (or port):
MqttX.Server.start_link(MyApp.MqttHandler, [], name: MyApp.Broker, port: 1883)
MqttX.Server.deliver(MyApp.Broker, "device-123/cmd", "reboot", %{qos: 1})
```

### Pushing to one connection from your app

To bridge from your application (Phoenix.PubSub, a GenServer, an Oban worker,
…) to one connected MQTT client, send a message to its connection process and
return a `{:publish, ...}` tuple from `handle_info/2`:

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  def init(_), do: %{}

  def handle_connect(client_id, _creds, _info, state) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "client:#{client_id}")
    {:ok, state}
  end

  def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
  def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
  def handle_disconnect(_reason, _state), do: :ok

  def handle_info({:downlink, topic, payload}, state) do
    {:publish, topic, payload, %{qos: 1, retain: false}, state}
  end
end
```

Then anywhere in your app:

```elixir
Phoenix.PubSub.broadcast(MyApp.PubSub, "client:device-123",
  {:downlink, "device-123/cmd", "reboot"})
```

When the topic matches one of the client's subscriptions, the delivery honors
that subscription's options: QoS is capped at the granted QoS, `retain` is
forwarded only for Retain-As-Published subscriptions, and subscription
identifiers are attached. Pass `publisher: originating_client_id` in the opts
to honor `no_local`. A publish matching no subscription is sent exactly as
given.

### MQTT 5.0 persistent sessions (resume after disconnect)

In MQTT 5.0 the client tells the broker how long to keep its session via
`:session_expiry_interval` and resumes by reconnecting with the same
`client_id` and `clean_session: false`:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "device-imei-490154203237518",
  protocol_version: 5,
  clean_session: false,
  connect_properties: %{session_expiry_interval: 3600},
  session_store: MqttX.Session.ETSStore
)
```

A spec-compliant broker queues QoS 1/2 messages while the client is offline
(up to 1 hour in this example) and replays them on reconnect. Note that
MqttX's *own* broker does not implement offline queueing — see `MqttX.Server`
if you are running MqttX as the broker.

## Common Pitfalls

- **`connect/1` does not wait for the broker.** It returns as soon as the
  client process starts, so a `subscribe`/`publish` issued immediately after
  gets `{:error, :not_connected}`. Subscribe once the session is live, or pass
  `await_connect: true`. The async default lets a client start before its
  broker is reachable and retry with backoff.
- **`clean_session: false` does nothing without `:session_store`.** The flag
  tells the broker to keep state — but for the *client* to resume QoS 1/2
  in-flight on reconnect, you must also pass a `:session_store` module.
- **Server's `:server_keep_alive` caps the client.** When set in
  `transport_opts`, an MQTT 5.0 client asking for a longer Keep Alive (or
  none) is told the cap in CONNACK and must use it; a shorter one stands.
  Useful for surviving cloud-proxy idle timeouts.
- **`:max_packet_size` is enforced both ways.** A client that sends a packet
  larger than the broker's limit gets DISCONNECT 0x95; the reverse is also
  true if the client advertises one in CONNECT properties.
- **Topic wildcards in PUBLISH are illegal.** `+` and `#` are subscribe-only —
  use `MqttX.Topic.validate_publish/1` on untrusted input.
- **`$SYS/...` topics need explicit subscription.** Per MQTT §4.7.2, `#` and
  `+/...` subscribers do *not* receive `$`-prefixed topics; subscribe to
  `$SYS/#` directly.

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
  port: 1883,
  # :ranch_tcp (default) or :ranch_ssl — note this option was named
  # `:transport` before v0.11.0, which collided with the adapter selector above
  ranch_transport: :ranch_tcp
)
```

### WebSocket

```elixir
# ws://
MqttX.Server.start_link(
  MyHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8083
)

# wss://
MqttX.Server.start_link(
  MyHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8084,
  scheme: :https,
  transport_options: [certfile: "/etc/mqttx/cert.pem", keyfile: "/etc/mqttx/key.pem"]
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

### Publishing with a codec

Pass the term and the codec; the payload is encoded and the codec's MQTT 5.0
`payload_format_indicator` / `content_type` go out with it:

```elixir
MqttX.Client.publish(client, "sensors/room1", %{temp: 21.5},
  qos: 1,
  codec: MqttX.Payload.JSON
)
```

See the [Codec guide](https://hexdocs.pm/mqttx/codec.html#publishing-with-a-codec).

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

- **Server**: CONNACK capability properties, protocol ordering enforcement, topic alias validation, MQTT 5.0 property forwarding, subscription options (no_local, retain_as_published, retain_handling, subscription identifiers), server keepalive override, enhanced AUTH (exchange before CONNACK, re-authentication)
- **Client**: server_keep_alive override, assigned_client_identifier, maximum_packet_size enforcement, server_reference handling, enhanced AUTH (multi-step), flow control (receive_maximum)

Validated against Mosquitto (104 automated protocol tests across TCP and WebSocket) and EMQX Cloud (49 interop tests covering all QoS levels, properties, session persistence, and subscription options).

### MQTT 5.0 Server Features

**Server CONNACK properties** (sent to MQTT 5.0 clients):

| Property | Default | Configurable |
|----------|---------|--------------|
| `shared_subscription_available` | `1` | No |
| `topic_alias_maximum` | `100` | Yes (`transport_opts`) |
| `receive_maximum` | `100` | Yes (`transport_opts`) |
| `retain_available` | `1` | No |
| `wildcard_subscription_available` | `1` | No |
| `subscription_identifier_available` | `1` | No |
| `server_keep_alive` | Not sent | Yes (`transport_opts`) |
| `maximum_packet_size` | Not sent | Yes (`transport_opts`) |
| `session_expiry_interval` | Not sent | Sent when the client asked for more than `max_session_expiry_interval` (`transport_opts`) |

**`transport_opts` configuration:**

```elixir
MqttX.Server.start_link(
  MyHandler,
  [transport_opts: %{
    server_keep_alive: 30,           # override client keepalive (v5)
    topic_alias_maximum: 100,        # max topic aliases
    receive_maximum: 100,            # max inflight QoS>0
    max_packet_size: 256_000,        # reject oversized packets
    max_outbound_queue: 10_000,      # publishes queued per session (window + offline)
    max_session_expiry_interval: 86_400  # longest a session outlives its connection
  }],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

**`handle_connect` callback:**

The optional 4-arity `handle_connect/4` receives connection metadata separately from credentials:

```elixir
# credentials (both arities):
%{username: "device_imei", password: "secret"}

# connect_info (4-arity only):
%{protocol_version: 5, keep_alive: 50, authentication_method: nil,
  session_present: true, subscriptions: [%{topic: "sensors/#", qos: 1, ...}]}
```

Use `handle_connect/4` to log the protocol version, make version-specific
decisions, or see which session the client is resuming (`session_present`
and the `subscriptions` coming back with it). Existing `handle_connect/3`
handlers continue to work unchanged.

**Sessions:** the broker keeps Session State per listener, in ETS. A client
connecting with Clean Start 0 and a Session Expiry Interval (or CleanSession 0
on 3.1.1) gets `session_present: true` on reconnect, its subscriptions back,
unacknowledged QoS 1/2 messages re-sent, and whatever `deliver/3` queued while
it was away. Sessions are kept for at most `max_session_expiry_interval`
(default one day), in memory on the node holding them; a `session_backend`
(e.g. `MqttX.Server.SessionBackend.DETS`) saves them across restarts;
`MqttX.Server.SessionBackend.Replicated` keeps them on every node of a cluster,
and the server guide has an Ecto/Postgres backend for a database.

**Clustering:** listeners started with the same `:name` on connected nodes
act as one broker — `deliver/3` reaches every node, a session follows its
client to whichever node it connects to, and retained messages and shared
subscriptions are cluster-wide. See the Clustering section of the server
guide.

## Performance

Architected to scale from tens of thousands to **roughly a million concurrent devices** on a single BEAM node, depending on hardware and workload. Each connection is a lightweight Erlang process (~20KB of BEAM state plus ~4-8KB of kernel socket buffers), and the hot paths are optimized for high message throughput:

- **Trie-based topic router**: O(L+K) matching where L = topic depth, K = matching subscriptions — independent of total subscription count
- **iodata encoding**: Socket sends use iodata directly, avoiding binary copies on every packet
- **Zero-copy binary references**: Decoder returns sub-binaries for payload and topic
- **Declared-length reassembly**: A packet spanning many TCP reads is collected without copying and assembled once — linear, where per-read concatenation was quadratic
- **Cached callback dispatch**: `function_exported?` computed once at connection init, not per message
- **Direct inflight counter**: O(1) flow control check instead of scanning pending_acks
- **ETS match-spec retained delivery**: Exact filters are one lookup; wildcard filters traverse only the key range their literal prefix bounds

Capacity depends on hardware, so these figures are anchored to instance sizes
rather than given as a single ceiling. Devices are the practical targets from
the [capacity planning](https://hexdocs.pm/mqttx/performance.html#capacity-planning) method, which
reserves headroom for the runtime, ETS, and reconnect storms:

| Instance | Idle-ish devices (~1 msg/min) | Chatty devices (1 msg/sec) | Binding constraint |
|----------|------------------------------|----------------------------|--------------------|
| 1 vCPU / 2 GB | ~50,000 | ~15,000 | RAM / CPU |
| 4 vCPU / 16 GB | ~400,000 | ~60,000 | RAM, fds, kernel memory |
| 16 vCPU / 128 GB | ~1,000,000 | ~160,000 | ETS contention, accept rate |

Beyond roughly 500K connections per node the limit stops being RAM and becomes
kernel socket memory, file descriptors, and contention on shared ETS tables —
none of which improve with more cores — so horizontal scaling usually beats a
larger instance. Message-rate figures assume small QoS 0 payloads, plaintext
TCP, and a handler doing negligible work.

> **The device counts are estimates from architectural analysis** — nobody
> has load-tested a million connections here. Per-message cost, on the other
> hand, is measured end to end (below). See the
> [Performance & Scaling guide](https://hexdocs.pm/mqttx/performance.html) for the sizing formula,
> per-vCPU throughput, and the caveats behind each number.

**Codec benchmarks vs mqtt_packet_map** — measured, on an Apple M4 Pro:

| Operation | MqttX | mqtt_packet_map | Result |
|-----------|-------|-----------------|--------|
| PUBLISH encode | 5.05M ips | 1.72M ips | **2.9x faster** |
| SUBSCRIBE encode | 3.42M ips | 0.82M ips | **4.2x faster** |
| PUBLISH decode | 2.36M ips | 2.25M ips | ~same |

**End-to-end, MqttX client ↔ MqttX broker over loopback** — measured on the
same machine with `mix run bench/e2e.exs` (one publisher; fan-out is one
PUBLISH forwarded to 50 subscribed connections):

| Scenario | 100 B | 4 KiB | 64 KiB |
|----------|-------|-------|--------|
| Uplink QoS 0 | 164k msg/s | 100k msg/s | 25k msg/s (1.6 GB/s) |
| Uplink QoS 1 (every PUBACK awaited) | 98k msg/s | 82k msg/s | 18k msg/s |
| Fan-out 1 → 50 | 450k deliveries/s | 425k deliveries/s | 117k deliveries/s (7.7 GB/s) |

WebSocket figures, the receive-buffer and retained-store measurements, and
how to run the suites yourself are in
[Measured Throughput](https://hexdocs.pm/mqttx/performance.html#measured-throughput);
`mix test --include load` runs a many-client completeness check.

The performance guide also covers [VM tuning](https://hexdocs.pm/mqttx/performance.html#vm-tuning) (`+P`/`+Q`
limits, which you *must* raise past 65K connections), OS tuning, and
multi-node deployment.

## Guides

[Getting Started](https://hexdocs.pm/mqttx/getting-started.html) ·
[Why MQTT for IoT](https://hexdocs.pm/mqttx/why-mqtt-for-iot.html) ·
[Client](https://hexdocs.pm/mqttx/client.html) ·
[Server / Broker](https://hexdocs.pm/mqttx/server.html) ·
[Packet Codec](https://hexdocs.pm/mqttx/codec.html) ·
[Telemetry](https://hexdocs.pm/mqttx/telemetry.html) ·
[Performance & Scaling](https://hexdocs.pm/mqttx/performance.html)

## API Reference

### MqttX.Client

| Function | Description |
|----------|-------------|
| `connect(opts)` | Connect to an MQTT broker |
| `connect_supervised(opts)` | Connect under `MqttX.Client.Supervisor` with crash recovery |
| `list()` | List all registered client connections |
| `whereis(client_id)` | Look up a connection by client_id |
| `publish(client, topic, payload, opts \\ [])` | Publish a message. Options: `:qos` (0-2), `:retain` (boolean), `:properties` (MQTT 5.0) |
| `subscribe(client, topics, opts \\ [])` | Subscribe to topics. Options: `:qos` (0-2), `:no_local`, `:retain_as_published`, `:retain_handling`, `:properties` (MQTT 5.0) |
| `unsubscribe(client, topics)` | Unsubscribe from topics |
| `disconnect(client)` | Disconnect from the broker |
| `connected?(client)` | Check if client is connected |

**Connect Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `:host` | Broker hostname | *required* |
| `:port` | Broker port | `1883` / `8883` / `8083` / `8084` |
| `:client_id` | Client identifier | *required* |
| `:username` | Authentication username | `nil` |
| `:password` | Authentication password | `nil` |
| `:clean_session` | Start fresh session | `true` |
| `:keepalive` | Keep-alive interval (seconds) | `60` |
| `:await_connect` | Block until the first CONNACK resolves (see [Common Pitfalls](#common-pitfalls)) | `false` |
| `:protocol_version` | MQTT protocol level: `3`, `4` (3.1.1) or `5` | `5` |
| `:transport` | `:tcp`, `:ssl`, `:ws`, or `:wss` | `:tcp` |
| `:ssl_opts` | SSL options, merged **over** the secure baseline (see [TLS/SSL](https://hexdocs.pm/mqttx/client.html#tls-ssl)) | `[]` |
| `:ws_path` | WebSocket path for `:ws` or `:wss` | `"/mqtt"` |
| `:proxy` | HTTP CONNECT proxy, e.g. `[host: "proxy.corp", port: 3128, auth: {"u", "p"}]` | `nil` |
| `:max_inflight` | Max pending QoS 1/2 messages | `100` |
| `:max_packet_size` | Reject inbound packets declaring more than this (`:infinity` disables) | `1 MiB` |
| `:will_topic` / `:will_payload` / `:will_qos` / `:will_retain` / `:will_properties` | Last Will & Testament | `nil` / `""` / `0` / `false` / `%{}` |
| `:connect_properties` | MQTT 5.0 CONNECT properties (e.g. `%{session_expiry_interval: 3600}`) | `%{}` |
| `:session_store` | Session store module | `nil` |
| `:handler` | Callback module for messages | `nil` |
| `:handler_state` | Initial handler state | `nil` |

Unacknowledged QoS 1/2 publishes are held until the broker acknowledges them
and re-sent only when a session is resumed after a reconnect (MQTT §4.4) —
never on a live connection. `:retry_interval` is deprecated and ignored
since 0.12.0.

### MqttX.Server

| Function | Description |
|----------|-------------|
| `start_link(handler, handler_opts, opts)` | Start an MQTT server. Options: `:transport`, `:port`, `:name`, `:rate_limit`, `:ip`. Protocol options go in `handler_opts` under `:transport_opts` |
| `deliver(topic, payload, opts)` | From a callback: fan a message out to every session subscribed to `topic` on this listener, queueing QoS 1/2 for sessions that are away. Returns `{:ok, n}` |
| `deliver(listener, topic, payload, opts)` | The same from any process, by the listener's `:name` or port |
| `disconnect(pid, reason_code, properties)` | Send DISCONNECT to a connection and close it |

**Callbacks:**

| Callback | Description |
|----------|-------------|
| `init(opts)` | Initialize handler state |
| `handle_connect(client_id, credentials, state)` | Handle client connection. Return `{:ok, state}` or `{:error, reason_code, state}` |
| `handle_connect(client_id, credentials, connect_info, state)` | *(optional)* Same as above with connection metadata (`protocol_version`, `keep_alive`, `authentication_method`, `session_present`, `subscriptions`). Takes precedence over 3-arity when defined |
| `handle_publish(topic, payload, opts, state)` | Handle incoming PUBLISH. Return `{:ok, state}` |
| `handle_subscribe(topics, state)` | Handle SUBSCRIBE. Return `{:ok, granted_qos_list, state}` |
| `handle_unsubscribe(topics, state)` | Handle UNSUBSCRIBE. Return `{:ok, state}` |
| `handle_disconnect(reason, state)` | Handle client disconnection. Return `:ok` |
| `handle_session_expired(client_id, state)` | *(optional)* The client's session ended after its connection did; the broker has dropped its own state for it. Return `:ok` |
| `handle_info(message, state)` | Handle custom messages. Return `{:ok, state}`, `{:publish, topic, payload, state}`, `{:publish, topic, payload, opts, state}`, `{:disconnect, reason_code, state}`, `{:disconnect, reason_code, properties, state}`, or `{:stop, reason, state}` |

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
| **Clustering** | Done | Listeners sharing a `:name` form one broker across nodes via `:pg`: cluster-wide `deliver/3`, takeover and session resumption on any node, replicated retained messages, shared subscriptions delivered once cluster-wide |
| **Session Persistence (Server)** | Done | Session State per listener in ETS: `session_present`, subscriptions and in-flight QoS 1/2 resume on reconnect, `MqttX.Server.deliver/3` queues for sessions that are away. Optional durable `MqttX.Server.SessionBackend` (DETS and cluster-replicated built in) survives restarts or the loss of a node |
| **MQTT 5.0 Enhanced Auth** | Done | Challenge–response exchange before CONNACK and re-authentication, on both client and broker, via `handle_auth/3`; the mechanism itself (SCRAM, tokens, …) is the handler's — no built-in providers |
| **Telemetry Docs** | Done | See the [Telemetry guide](https://hexdocs.pm/mqttx/telemetry.html) |
| **Property-based Tests** | Done | StreamData round-trips + decode/encode fuzzing of the codec |
| **End-to-end Load Tests** | Done | Benchee suites in `bench/` (codec, router/retained/buffer, client↔broker over loopback) + `mix test --include load`; numbers in the [Performance guide](https://hexdocs.pm/mqttx/performance.html#measured-throughput) |

## License

Apache-2.0