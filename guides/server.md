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
| `handle_connect(client_id, credentials, connect_info, state)` | *(optional)* Same as the 3-arity form plus `%{protocol_version:, keep_alive:, authentication_method:}`; takes precedence when defined |
| `handle_connect(client_id, credentials, state)` | `{:ok, state}` or `{:error, reason_code, state}` |
| `handle_publish(topic, payload, opts, state)` | `{:ok, state}`, `{:error, reason, state}` (refused but still acknowledged — QoS 1 gets a PUBACK with a refusal code, e.g. `0x87` for `:unauthorized`), `{:disconnect, reason_code, state}` |
| `handle_subscribe(topics, state)` | `{:ok, granted_qos_list, state}`, `{:disconnect, reason_code, state}` |
| `handle_unsubscribe(topics, state)` | `{:ok, state}`, `{:disconnect, reason_code, state}` |
| `handle_disconnect(reason, state)` | `:ok` |
| `handle_info(message, state)` | `{:ok, state}`, `{:publish, ...}`, `{:disconnect, reason_code, state}`, or `{:stop, reason, state}` |
| `handle_puback(packet_id, state)` | `{:ok, state}` *(optional)* — a QoS 1 PUBLISH you sent was acknowledged |
| `handle_auth(method, data, state)` | `{:ok, state}`, `{:ok, data, state}`, `{:continue, data, state}`, or `{:error, reason_code, state}` *(optional, MQTT 5.0 enhanced auth — see [Enhanced Authentication](#enhanced-authentication))* |
| `handle_session_expired(client_id, state)` | `:ok` (optional) |

Use `handle_info/2` with `{:publish, topic, payload, state}` to push messages to connected clients from external events (e.g., PubSub). When the topic matches one of the client's subscriptions, the delivery honors the subscription's options: QoS is capped at the granted QoS, `retain` is forwarded only if the subscription set Retain As Published, and subscription identifiers are attached. Pass `publisher: originating_client_id` in the opts to honor `no_local` subscriptions. A publish matching no subscription is sent exactly as given.

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
  port: 1883,
  # :ranch_tcp (default) or :ranch_ssl. Named `:transport` before v0.11.0,
  # which collided with the adapter selector above.
  ranch_transport: :ranch_tcp
)
```

### WebSocket

```elixir
# mix.exs: {:bandit, "~> 1.6"}, {:websock_adapter, "~> 0.5 or ~> 0.6"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8083
)

# wss:// — the same TLS options ThousandIsland's SSL transport takes
{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8084,
  scheme: :https,
  transport_options: [certfile: "/etc/mqttx/cert.pem", keyfile: "/etc/mqttx/key.pem"]
)
```

All transports support plain TCP and TLS. See `MqttX.Transport` for implementing custom adapters.

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

### Shared Subscriptions

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
- **QoS 0**: Messages are silently dropped
- **QoS 1 / 2**: PUBACK / PUBREC is sent with reason code `0x97` (Quota
  exceeded) and the message is not delivered; the session stays up. (`0x96`
  Message rate too high exists only for DISCONNECT, §2.4.)

When the connection rate limit is exceeded, new connections are immediately closed.

Rate limiting uses ETS with atomic `update_counter` operations, making it lock-free and safe for concurrent access from multiple transport handler processes.

## Retained Messages

The server automatically stores retained messages in ETS and delivers them to new subscribers. Publish with an empty payload to clear a retained message.

## Keepalive Timeout

The server enforces MQTT keepalive as defined in the spec: if no packet is received from a client within 1.5x the `keep_alive` interval (set in the CONNECT packet), the server disconnects the client and publishes any will message.

The keepalive timer resets on every received packet (not just PINGREQ). Clients that set `keep_alive: 0` are exempt from keepalive enforcement — but not from the idle ceiling below.

When a keepalive timeout fires, your `handle_disconnect/2` callback receives `:keepalive_timeout` as the reason.

### Idle ceiling

Because MQTT keepalive does not apply when a client connects with
`keep_alive: 0`, the server additionally closes any socket idle for longer
than `:max_idle_timeout` (default 15 minutes), regardless of the negotiated
Keep Alive. The timer resets on any inbound data, so it never interferes with
a client that is honoring its keepalive. `handle_disconnect/2` receives
`:idle_timeout`.

```elixir
transport_opts: %{max_idle_timeout: 900_000}   # :infinity disables
```

A separate `:connect_timeout` (default 10 s) closes sockets that never
complete CONNECT.

## Will Messages

Will messages from the CONNECT packet are published automatically whenever
the connection ends without the client having sent `DISCONNECT 0x00`
(§3.1.2.5): a socket drop, a keep-alive or idle timeout, a protocol error,
a handler's `{:disconnect, ...}` return, `MqttX.Server.disconnect/3`, and a
session takeover by a new connection with the same client id. Only the
client's own normal DISCONNECT discards the Will (a `DISCONNECT 0x04` asks
for it to be published). The Will's topic and payload are offered to
`handle_publish/4` like any other message, so your authorization applies.

### Will Delay Interval (MQTT 5.0)

MQTT 5.0 clients can set `will_delay_interval` in the will properties to delay publication of the will message:

- `will_delay_interval: 0` (or MQTT 3.1.1) — will published immediately (default)
- `will_delay_interval: N` — will published N seconds after ungraceful disconnect

This allows a grace period for clients to reconnect before their "last will"
is broadcast: a new connection for the same client id within the delay
cancels the pending Will (§3.1.3.2.2), as does a session takeover. The delay
needs a non-zero Session Expiry Interval — with the default of 0 the session
ends at disconnect and the Will is published at once.

## Session State

The server operates in clean-session mode **for every protocol version**:
`session_present` is always `false` in CONNACK, and session state
(subscriptions, queued messages, in-flight QoS 1/2) is not persisted across
reconnections. A client that connects with `clean_session: false` therefore
gains nothing against *this* broker, though it works as expected against EMQX,
Mosquitto, and other brokers. If your application needs session resumption,
implement it at the handler level using `handle_connect/3` and a session store.

## Session Expiry (MQTT 5.0)

MQTT 5.0 clients can set `session_expiry_interval` in the CONNECT properties. After the client disconnects, the server waits the specified interval then calls your `handle_session_expired/2` callback.

The timer is supervised and **cancelled if the same client reconnects within
the window**, so expiry never fires for a session that resumed in time. A
client may also revise the interval in its DISCONNECT packet (§3.14.2.2.2) —
commonly `session_expiry_interval: 0` meaning "drop my session now".

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

The server enforces `receive_maximum` for incoming QoS 1 and QoS 2 messages:

- Advertises `receive_maximum` in CONNACK (default: 65535, configurable via `transport_opts`)
- Tracks in-flight QoS 2 messages (between PUBREC and PUBCOMP)
- A client that sends more QoS > 0 publishes than that is disconnected with
  `0x93` (Receive Maximum exceeded) — the Protocol Error §4.9 prescribes;
  there is no per-message refusal code for it

In the other direction the broker honours the client's Receive Maximum:
outbound QoS > 0 publishes beyond the window wait in a per-connection queue
bounded by `:max_outbound_queue` (default 10 000, `:infinity` disables) and
are sent as acknowledgements free capacity, with any Message Expiry Interval
reduced by the time spent waiting and expired messages dropped. Outbound
Packet Identifiers are never reused while still in flight. A client that
connects with a zero-length client id is assigned one, which `handle_connect`
receives and a v5 client reads from the CONNACK's Assigned Client Identifier.

### Maximum Packet Size

Incoming packets are capped at **1 MiB by default** (since v0.11.0) and the
limit is enforced on the *declared* remaining length before the body is
buffered, so an unauthenticated peer cannot force a large allocation. Override
or disable it with `:infinity`:

```elixir
# NOTE: protocol options live in `transport_opts` inside the *handler options*
# (2nd argument), not the transport options (3rd argument).
MqttX.Server.start_link(
  MyApp.MqttHandler,
  [transport_opts: %{max_packet_size: 1_048_576}],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

- Server sends DISCONNECT with reason code `0x95` (Packet too large) for oversized incoming packets
- Retained storage is likewise bounded by `:max_retained_messages`
  (default 100_000 distinct topics)
- Outgoing publishes exceeding the client's advertised `maximum_packet_size` are silently dropped
- Server advertises its `maximum_packet_size` in CONNACK when configured

### Message Delivery Retry

MQTT §4.4 allows an unacknowledged QoS 1/2 PUBLISH or PUBREL to be re-sent
only when a session is resumed — never on a live connection, where TCP
already guarantees delivery and a missing acknowledgement means the peer is
slow or gone, which the keep-alive timeout detects. The broker therefore:

- Holds outgoing QoS 1/2 messages until the client acknowledges them, bounded
  by the client's Receive Maximum
- Holds an incoming QoS 2 message until PUBREL releases it, bounded by
  `:receive_maximum`
- Re-sends PUBREC only in reply to a duplicate PUBLISH (`dup: true`), without
  re-storing the message
- Runs no retransmission timer — `qos2_retry_interval` and `qos2_max_retries`
  are deprecated and ignored since 0.12.0

`MqttX.Server` does not persist sessions, so in-flight state ends with the
connection.

### Enhanced Authentication

A client that sends an Authentication Method in its CONNECT asks for an
MQTT 5.0 enhanced authentication exchange (§4.12). After `handle_connect`
accepts, the broker calls `handle_auth(method, data, state)` with the
CONNECT's Authentication Data (`nil` if none) and holds the CONNACK until the
exchange ends:

- `{:continue, challenge, state}` sends `AUTH 0x18` carrying `challenge`; the
  client's `AUTH 0x18` reply comes back through `handle_auth/3`
- `{:ok, state}` or `{:ok, server_final, state}` sends `CONNACK 0x00`, which
  repeats the Authentication Method (MQTT-4.12.0-5) and carries `server_final`
  as Authentication Data when given
- `{:error, reason_code, state}` sends a CONNACK with that code and closes the
  connection — `0x87` Not authorized for a failed proof, `0x8C` Bad
  authentication method for a mechanism you do not support

The same callback handles re-authentication (`AUTH 0x19`) on a live
connection, where success is `AUTH 0x00` and failure a DISCONNECT. During the
exchange any packet other than AUTH, an AUTH naming a different method, or an
AUTH with a reason code other than `0x18`, fails the CONNECT (`0x82` / `0x8C`);
a stalled exchange is ended by the CONNECT deadline, and a connection dropped
before CONNACK fires neither the Will nor `handle_disconnect/2`. An AUTH on a
connection whose CONNECT named no method is refused with `0x8C`.

The default `handle_auth/3` returns `{:error, 0x8C, state}`, so clients
asking for enhanced authentication are refused unless you implement it. The
mechanism itself — SCRAM, a token exchange — is yours to implement; see the
`handle_auth/3` docs on `MqttX.Server` for a SCRAM-shaped example.

### Shared Subscription Availability

The server advertises `shared_subscription_available: 1` in CONNACK. See
[Shared Subscriptions](#shared-subscriptions) under Topic Routing for usage.

### CONNACK Properties

For MQTT 5.0 connections, the server automatically includes these properties in CONNACK:

| Property | Value | Description |
|----------|-------|-------------|
| `shared_subscription_available` | `1` | Shared subscriptions supported |
| `topic_alias_maximum` | `100` | Max topic aliases the server accepts |
| `receive_maximum` | `65535` | Max in-flight QoS 1/2 messages |
| `maximum_packet_size` | *(if configured)* | Max incoming packet size in bytes |
| `retain_available` | `1` | Retained messages supported |
| `wildcard_subscription_available` | `1` | Wildcard subscriptions supported |
| `subscription_identifier_available` | `1` | Subscription identifiers attached to routed deliveries |

### Publish Properties

The `opts` map passed to `handle_publish/4` includes a `:properties` key containing any MQTT 5.0 publish properties sent by the client (e.g., `user_properties`, `content_type`, `correlation_data`, `response_topic`, `payload_format_indicator`, `message_expiry_interval`). These properties are also forwarded when the server sends outgoing PUBLISH messages via `handle_info/2`.

### Subscription Options

The server supports MQTT 5.0 subscription options:

- **`no_local`**: When set to `true`, messages published by a client are not delivered back to that client's own matching subscriptions. Requires passing the publisher identity to `Router.match/3`.
- **`retain_handling`**: Controls retained message delivery on subscribe:
  - `0` — Send retained messages (default)
  - `1` — Send retained messages if the subscription does not already exist
  - `2` — Do not send retained messages on subscribe

---

← Back to the [documentation index](../README.md#guides)
