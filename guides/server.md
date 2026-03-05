# Server Guide

`MqttX.Server` is a behaviour for building MQTT brokers. You implement handler callbacks; MqttX handles the protocol, transport, and routing.

## Handler Callbacks

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  @impl true
  def init(_opts), do: %{subscriptions: %{}}

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
  def handle_unsubscribe(_topics, state), do: {:ok, state}

  @impl true
  def handle_disconnect(reason, _state) do
    IO.puts("Client disconnected: #{inspect(reason)}")
    :ok
  end

  @impl true
  def handle_info(message, state) do
    # Handle custom messages (e.g., Phoenix.PubSub broadcasts)
    {:ok, state}
  end
end
```

### Callback Summary

| Callback | Return |
|----------|--------|
| `init(opts)` | `state` |
| `handle_connect(client_id, credentials, state)` | `{:ok, state}` or `{:error, reason_code, state}` |
| `handle_publish(topic, payload, opts, state)` | `{:ok, state}`, `{:disconnect, reason_code, state}` |
| `handle_subscribe(topics, state)` | `{:ok, granted_qos_list, state}`, `{:disconnect, reason_code, state}` |
| `handle_unsubscribe(topics, state)` | `{:ok, state}`, `{:disconnect, reason_code, state}` |
| `handle_disconnect(reason, state)` | `:ok` |
| `handle_info(message, state)` | `{:ok, state}`, `{:publish, ...}`, `{:disconnect, reason_code, state}`, or `{:stop, reason, state}` |
| `handle_session_expired(client_id, state)` | `:ok` (optional) |

Use `handle_info/2` with `{:publish, topic, payload, state}` to push messages to connected clients from external events (e.g., PubSub).

Any callback that returns `{:disconnect, reason_code, state}` or `{:disconnect, reason_code, properties, state}` will send an MQTT 5.0 DISCONNECT packet to the client and close the connection.

## Transport Adapters

### ThousandIsland (Recommended)

```elixir
# mix.exs: {:thousand_island, "~> 1.4"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

### Ranch

```elixir
# mix.exs: {:ranch, "~> 2.2"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.Ranch,
  port: 1883
)
```

### WebSocket

```elixir
# mix.exs: {:bandit, "~> 1.6"}, {:websock_adapter, "~> 0.5"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8083
)
```

All transports support TCP and TLS. See `MqttX.Transport` for implementing custom adapters.

## Topic Routing

The built-in router uses a trie data structure for efficient topic matching — O(L+K) where L is the topic depth and K is matching subscriptions. It supports MQTT wildcard subscriptions (`+` single-level, `#` multi-level):

```elixir
alias MqttX.Server.Router

router = Router.new()
router = Router.subscribe(router, "sensors/+/temp", client_ref, qos: 1)
router = Router.subscribe(router, "alerts/#", client_ref, qos: 0)

matches = Router.match(router, "sensors/room1/temp")
# => [{client_ref, %{qos: 1}}]
```

### Shared Subscriptions (MQTT 5.0)

Distribute messages across a group of subscribers with round-robin load balancing:

```elixir
router = Router.subscribe(router, "$share/workers/jobs/#", worker1, qos: 1)
router = Router.subscribe(router, "$share/workers/jobs/#", worker2, qos: 1)

# Messages to "jobs/process" alternate between worker1 and worker2
{matches, router} = Router.match_and_advance(router, "jobs/process")
```

## Rate Limiting

MqttX supports per-client connection and message rate limiting. Configure it via the `:rate_limit` option:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883,
  rate_limit: [
    max_connections: 100,    # new connections per second
    max_messages: 1000,      # messages per client per second
    interval: 1000           # window size in ms (default)
  ]
)
```

| Option | Description | Default |
|--------|-------------|---------|
| `:max_connections` | Max new connections per interval | unlimited |
| `:max_messages` | Max messages per client per interval | unlimited |
| `:interval` | Counter reset interval in ms | `1000` |

When a client exceeds the message rate limit:
- **QoS 0**: Messages are silently dropped (per MQTT spec)
- **QoS 1+**: PUBACK is sent with reason code `0x96` (message_rate_too_high)

When the connection rate limit is exceeded, new connections are immediately closed.

Rate limiting uses ETS with atomic `update_counter` operations, making it lock-free and safe for concurrent access from multiple transport handler processes.

## Retained Messages

The server automatically stores retained messages in ETS and delivers them to new subscribers. Publish with an empty payload to clear a retained message.

## Keepalive Timeout

The server enforces MQTT keepalive as defined in the spec: if no packet is received from a client within 1.5x the `keep_alive` interval (set in the CONNECT packet), the server disconnects the client and publishes any will message.

The keepalive timer resets on every received packet (not just PINGREQ). Clients that set `keep_alive: 0` are exempt from timeout enforcement.

When a keepalive timeout fires, your `handle_disconnect/2` callback receives `:keepalive_timeout` as the reason.

## Will Messages

Will messages from the CONNECT packet are published automatically when a client disconnects without sending DISCONNECT.

### Will Delay Interval (MQTT 5.0)

MQTT 5.0 clients can set `will_delay_interval` in the will properties to delay publication of the will message:

- `will_delay_interval: 0` (or MQTT 3.1.1) — will published immediately (default)
- `will_delay_interval: N` — will published N seconds after ungraceful disconnect

This allows a grace period for clients to reconnect before their "last will" is broadcast.

## Session Expiry (MQTT 5.0)

MQTT 5.0 clients can set `session_expiry_interval` in the CONNECT properties. After the client disconnects, the server waits the specified interval then calls your `handle_session_expired/2` callback:

```elixir
@impl true
def handle_session_expired(client_id, state) do
  # Clean up stored subscriptions, queued messages, etc.
  MyApp.SessionStore.delete(client_id)
  :ok
end
```

| Value | Behavior |
|-------|----------|
| `nil` | No session expiry (MQTT 3.1.1 default) |
| `0` | Session expires immediately on disconnect |
| `1..0xFFFFFFFE` | Session expires after N seconds |
| `0xFFFFFFFF` | Session never expires |

## Server-Initiated Disconnect

Kick a client from the server with an MQTT 5.0 reason code:

```elixir
# From outside the handler (e.g., admin action)
MqttX.Server.disconnect(transport_pid, 0x98)
MqttX.Server.disconnect(transport_pid, 0x89, %{reason_string: "Session taken over"})
```

Or return `{:disconnect, reason_code, state}` from any handler callback:

```elixir
@impl true
def handle_publish(topic, _payload, _opts, state) do
  if forbidden?(topic) do
    {:disconnect, 0x98, state}  # Use assigned client identifier
  else
    {:ok, state}
  end
end
```

DISCONNECT packets are only sent for MQTT 5.0 connections. For MQTT 3.1.1, the connection is simply closed.

## MQTT 5.0 Protocol Features

The server automatically handles these MQTT 5.0 features when clients connect with protocol version 5:

### Topic Aliases

Clients can use topic aliases to reduce bandwidth by replacing repeated topic strings with short integer aliases. The server:

- Advertises `topic_alias_maximum: 100` in CONNACK (configurable via `transport_opts`)
- Resolves incoming topic aliases: first publish with alias + topic stores the mapping, subsequent publishes with alias only use the stored topic
- No application code needed — alias resolution is transparent to your handler callbacks

### Flow Control (Receive Maximum)

The server enforces `receive_maximum` for incoming QoS 2 messages:

- Advertises `receive_maximum` in CONNACK (default: 65535, configurable via `transport_opts`)
- Tracks in-flight QoS 2 messages (between PUBREC and PUBCOMP)
- Rejects excess QoS 2 publishes with PUBREC reason code `0x93` (Receive Maximum exceeded)

### Maximum Packet Size

Configure a maximum incoming packet size to protect against oversized messages:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883,
  transport_opts: %{max_packet_size: 1_048_576}  # 1MB limit
)
```

- Server sends DISCONNECT with reason code `0x95` (Packet too large) for oversized incoming packets
- Outgoing publishes exceeding the client's advertised `maximum_packet_size` are silently dropped
- Server advertises its `maximum_packet_size` in CONNACK when configured

### QoS 2 Retransmission

The server automatically retries stale QoS 2 handshake messages:

- Re-sends PUBREC if no PUBREL received within the retry interval (default: 5 seconds)
- Re-sends PUBLISH with `dup: true` for outgoing QoS 2 awaiting PUBREC
- Re-sends PUBREL for outgoing QoS 2 awaiting PUBCOMP
- Drops entries after max retries (default: 3)
- Handles DUP incoming PUBLISH by re-sending PUBREC without re-storing

### Shared Subscriptions

Distribute messages across a group of subscribers with `$share/group/topic` patterns. The server advertises `shared_subscription_available: 1` in CONNACK. See the [Topic Routing](#shared-subscriptions-mqtt-50) section above for usage.

### CONNACK Properties

For MQTT 5.0 connections, the server automatically includes these properties in CONNACK:

| Property | Value | Description |
|----------|-------|-------------|
| `shared_subscription_available` | `1` | Shared subscriptions supported |
| `topic_alias_maximum` | `100` | Max topic aliases the server accepts |
| `receive_maximum` | `65535` | Max in-flight QoS 2 messages |
| `maximum_packet_size` | *(if configured)* | Max incoming packet size in bytes |
| `retain_available` | `1` | Retained messages supported |
| `wildcard_subscription_available` | `1` | Wildcard subscriptions supported |
| `subscription_identifier_available` | `0` | Subscription identifiers not supported |

### MQTT 5.0 Publish Properties

The `opts` map passed to `handle_publish/4` includes a `:properties` key containing any MQTT 5.0 publish properties sent by the client (e.g., `user_properties`, `content_type`, `correlation_data`, `response_topic`, `payload_format_indicator`, `message_expiry_interval`). These properties are also forwarded when the server sends outgoing PUBLISH messages via `handle_info/2`.

### Session Handling

The server operates in clean-session mode: `session_present` is always `false` in CONNACK. Session state (subscriptions, queued messages) is not persisted across reconnections. If your application requires session resumption, implement it at the handler level using `handle_connect/3` and a session store.

### Subscription Options (MQTT 5.0)

The server supports MQTT 5.0 subscription options:

- **`no_local`**: When set to `true`, messages published by a client are not delivered back to that client's own matching subscriptions. Requires passing the publisher identity to `Router.match/3`.
- **`retain_handling`**: Controls retained message delivery on subscribe:
  - `0` — Send retained messages (default)
  - `1` — Send retained messages if the subscription does not already exist
  - `2` — Do not send retained messages on subscribe
