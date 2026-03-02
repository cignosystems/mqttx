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

Both adapters support TCP and TLS. See `MqttX.Transport` for implementing custom adapters.

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
