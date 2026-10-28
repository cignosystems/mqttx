# Client Guide

`MqttX.Client` provides a GenServer-based MQTT client with automatic reconnection and exponential backoff.

## Basic Connection

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client",
  username: "user",        # optional
  password: "secret",      # optional
  await_connect: true      # block until the session is live (see below)
)

{:ok, [1]} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")
:ok = MqttX.Client.disconnect(client)
```

### Return values

`subscribe/3` waits for the SUBACK and returns `{:ok, granted_qos_list}`.
`publish/4` returns `:ok` as soon as the packet is on the socket; QoS 1/2
acknowledgements are tracked in the background and a rejection arrives as a
`:publish_error` event. Both return `{:error, reason}` without sending
anything when:

| Error | From | Meaning |
|-------|------|---------|
| `:not_connected` | both | No live session; calls do not queue |
| `:invalid_qos` | both | `:qos` is not 0, 1 or 2 |
| `:qos_not_supported` | `publish` | `:qos` is above the **Maximum QoS** the broker advertised in CONNACK (AWS IoT Core advertises 1). The QoS is not lowered silently — publish again at a supported level |
| `:retain_not_supported` | `publish` | `retain: true`, but the broker advertised **Retain Available = 0** |
| `:flow_control` | `publish` | The QoS 1/2 in-flight window (`:max_inflight`, or the broker's Receive Maximum) is full |
| `:packet_too_large` | `publish` | Larger than the broker's Maximum Packet Size |
| `{:codec, reason}` | `publish` | The `:codec` could not encode the payload |
| `:invalid_retain_handling` | `subscribe` | `:retain_handling` is not 0, 1 or 2 |
| `:no_local_on_shared_subscription` | `subscribe` | `no_local: true` on a `$share/...` filter (a Protocol Error, MQTT-3.8.3-4) |
| `{:subscription_refused, acks}` | `subscribe` | The broker rejected at least one filter |

Asking `subscribe/3` for a QoS above the broker's Maximum QoS is allowed —
the broker grants a lower one — so only `publish/4` checks that limit.

An invalid `:will_qos` (not 0, 1 or 2) raises `ArgumentError` from
`connect/1` itself, since it would make every CONNECT a malformed packet.

### Connection is asynchronous by default

Without `await_connect: true`, `connect/1` returns as soon as the client
process starts — *before* the CONNECT/CONNACK handshake completes — so a
`subscribe` or `publish` issued immediately afterwards returns
`{:error, :not_connected}`. That default exists so a client can be started
before its broker is reachable and keep retrying with backoff, which is the
normal case for devices and for apps that boot alongside their broker. The
delay between attempts doubles up to 30 s and starts over only after a
connection that held for 30 s, so a broker that drops the client right
after CONNACK is not retried every second.

For long-lived clients you usually don't need to do anything: subscriptions
are **replayed automatically** after every reconnect that reports
`session_present: false`, so subscribe once and MqttX keeps it in place.

The `:connected` event tells you when the session is live. Note that handler
callbacks run *inside* the connection process, so you must not call
`MqttX.Client.subscribe/3` or `publish/4` on your own client from there — they
are `GenServer.call`s and would deadlock. Send yourself a message instead, or
use `use MqttX`, whose callbacks run in their own process and whose injected
`subscribe/2` and `publish/3` are safe to call directly.

`await_connect: true` is the right choice for scripts, tests, and one-shot
tasks: it returns `{:error, reason}` if the first attempt fails (and stops the
client) instead of leaving it retrying.

## Supervised Connections

Use `connect_supervised/1` to start connections under `MqttX.Client.Supervisor`. Supervised connections are automatically restarted on crash and registered in `MqttX.ClientRegistry` for lookup.

```elixir
# Start a supervised connection
{:ok, client} = MqttX.Client.connect_supervised(
  host: "localhost",
  port: 1883,
  client_id: "my_client"
)

# List all registered connections
MqttX.Client.list()
#=> [{"my_client", #PID<0.123.0>, %{host: "localhost", port: 1883}}]

# Look up by client_id
{pid, _meta} = MqttX.Client.whereis("my_client")
```

The supervisor uses a `:one_for_one` strategy — each connection is independent. If a connection process crashes, only that connection is restarted. The unsupervised `connect/1` function remains available for cases where you manage the lifecycle yourself.

## TLS / SSL

**Certificates are verified by default** (since v0.11.0). You do not need to
configure anything for a broker with a publicly-trusted certificate:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,
  client_id: "secure_client",
  transport: :ssl
)
```

The baseline applied to `:ssl` and `:wss` is `verify: :verify_peer` against the
OS trust store (`:public_key.cacerts_get/0`), SNI set to `:host`, HTTPS-style
hostname checking, and TLS 1.2/1.3 only. Anything you pass in `:ssl_opts` is
merged *over* that baseline, so you can still supply a private CA:

```elixir
ssl_opts: [cacertfile: "/etc/ssl/private-ca.pem"]
```

### Self-signed or expired certificates

Verification failure is the expected upgrade surprise when pointing at a
development broker with a self-signed certificate. To connect anyway you must
opt out explicitly — this disables the protection TLS provides and logs a
warning on every connect:

```elixir
ssl_opts: [verify: :verify_none]
```

Prefer supplying the broker's CA with `:cacertfile` over disabling verification.

When `:transport` is `:ssl`, the default port changes to `8883`.

## Connecting through an HTTP proxy

Networks that block direct outbound access to 1883/8883 usually permit HTTP
`CONNECT`. Pass `:proxy` to tunnel any transport (`:tcp`, `:ssl`, `:ws`,
`:wss`) through a forward proxy:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,
  client_id: "behind_proxy",
  transport: :ssl,
  proxy: [host: "proxy.corp", port: 3128, auth: {"user", "pass"}]
)
```

`:port` defaults to `3128` and `:auth` (HTTP Basic) is optional. TLS is
negotiated *through* the tunnel with the broker, so certificate verification
and SNI apply to the broker — not the proxy. A non-200 response from the proxy
fails that attempt with `{:proxy, {:proxy_status, code}}` and the usual
reconnect backoff applies.

## WebSocket Transport

Connect to brokers that expose MQTT over WebSocket:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8083,
  client_id: "ws_client",
  transport: :ws,
  ws_path: "/mqtt"
)
```

For secure WebSocket (WSS):

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8084,
  client_id: "wss_client",
  transport: :wss,
  ws_path: "/mqtt"
)
```

Default ports: `8083` for `:ws`, `8084` for `:wss`. The `:ws_path` defaults to `"/mqtt"`.

MQTT travels in WebSocket *binary* frames only (MQTT-6.0.0-1). A broker that
sends a text frame — or a frame with a reserved opcode — gets the connection
closed; the handler sees `{:disconnected, {:protocol_error, :non_binary_frame}}`
and the usual reconnect backoff applies. Ping, pong and close control frames
are handled as before.

## Session Persistence

For QoS 1/2 reliability across reconnects, disable clean sessions and provide a session store:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  client_id: "persistent_client",
  clean_session: false,
  session_store: MqttX.Session.ETSStore
)
```

The built-in `MqttX.Session.ETSStore` persists for the lifetime of the BEAM VM. Implement the `MqttX.Session.Store` behaviour for custom backends (Redis, database, etc.).

Persisted records carry `expires_at`, derived from the MQTT 5.0 Session Expiry Interval you send in `connect_properties` (the broker's CONNACK value wins if it sends one, and a `disconnect/2` with `properties: %{session_expiry_interval: n}` revises it). With MQTT 5.0 the interval defaults to `0` — the session ends at disconnect — so pass `connect_properties: %{session_expiry_interval: seconds}` (or `0xFFFFFFFF` for never) if you want it to survive. MQTT 3.1.1 sessions never expire locally. An expired record is discarded on the next connect instead of replaying stale in-flight state, and the ETS store sweeps expired records every 60 seconds (`config :mqttx, session_sweep_interval: ms`).

## Receiving Messages

Pass a `:handler` module that implements `handle_mqtt_event/3` to process incoming messages and lifecycle events:

```elixir
defmodule MyHandler do
  def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
    IO.puts("Received on #{inspect(topic)}: #{payload}")
    state
  end

  def handle_mqtt_event(:connected, _data, state) do
    IO.puts("Connected!")
    state
  end

  def handle_mqtt_event(:disconnected, reason, state) do
    IO.puts("Disconnected: #{inspect(reason)}")
    state
  end
end

{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  client_id: "my_client",
  handler: MyHandler,
  handler_state: %{}
)
```

The handler receives four event types:

| Event | Data | Description |
|-------|------|-------------|
| `:message` | `{topic, payload, packet}` | Incoming PUBLISH message. `topic` is a list of segments; `packet.properties.subscription_identifier` is an integer for one matching subscription, a list for several |
| `:connected` | `%{properties: props, session_present: bool}` | Connection established (props contains CONNACK properties) |
| `:disconnected` | reason | Connection lost — `:closed`, `:pingresp_timeout`, `{:error, posix}`, `{:protocol_error, reason}`, `{:server_disconnect, code, %{server_reference: ref}}`, or `{:connack_error, code, info}` for a non-retryable rejection |
| `:publish_error` | `{topic, packet_id, reason_code}` | The broker rejected one of your QoS 1/2 publishes (e.g. `0x87` not authorized, `0x97` quota exceeded) |

Give your handler a catch-all clause so new event types don't raise:

```elixir
def handle_mqtt_event(_event, _data, state), do: state
```

A raising handler is caught and logged rather than taking the connection down,
but the event's state update is lost.

Handler callbacks run **inside the connection process**, so calling
`MqttX.Client.subscribe/3` or `publish/4` on your own client from a handler
deadlocks — both are `GenServer.call`s waiting on the process that is currently
running your callback. Send yourself a message and act on it outside the
callback, or use [`use MqttX`](#module-based-clients-use-mqttx), whose
callbacks run in their own process.

## Module-based clients (`use MqttX`)

For a self-contained client — callbacks, connection, and supervision in one
module — `use MqttX` instead of writing a separate handler:

```elixir
defmodule MyApp.Sensors do
  use MqttX

  @impl true
  def init(_opts), do: {:ok, %{seen: 0}}

  @impl true
  def handle_connected(_info, state) do
    subscribe("sensors/#", qos: 1)
    {:ok, state}
  end

  @impl true
  def handle_message(topic, payload, _packet, state) do
    # Publishing from inside a callback is safe — callbacks run in this
    # module's own process, not inside the connection.
    publish("ack/" <> Enum.join(topic, "/"), payload, qos: 1)
    {:ok, %{state | seen: state.seen + 1}}
  end
end
```

Add it to a supervision tree with its connect options:

```elixir
children = [
  {MyApp.Sensors, host: "broker.example.com", client_id: "sensors-1"}
]
```

Callbacks — `init/1`, `handle_message/4`, `handle_connected/2`,
`handle_disconnected/2`, `handle_publish_error/4`, `handle_info/2` — all have
defaults, so implement only what you need. Each returns `{:ok, state}` or
`{:stop, reason, state}`. The macro also injects `publish/2,3`,
`subscribe/1,2`, `unsubscribe/1`, `connected?/0`, and `disconnect/0,1` on your
module, usable from inside callbacks or from anywhere else in your app. See
`MqttX.SimpleClient` for details.

The module's process is where its callbacks run, so the connection is not
held up by them — and is not held back by them either. A message is
acknowledged once it is in the module's mailbox, so with a slow
`handle_message/4` the mailbox grows without bound while the broker keeps
sending: the Receive Maximum the client advertises limits what the
connection holds, not what the module has yet to process. Keep the callback
quick (hand work to a `Task`, a queue, or a pool), or use the
`handle_mqtt_event/3` handler form, whose callback runs in the connection
process: a slow one there delays the acknowledgement, and a broker honouring
Receive Maximum then waits.

## MQTT 5.0 Features

### Request/Response

`MqttX.Client.request/4` sets up the MQTT 5.0 request/response pattern by subscribing to the response topic and publishing with `response_topic` and `correlation_data` properties. It returns the generated `correlation_data` for matching responses in your handler:

```elixir
{:ok, correlation_data} = MqttX.Client.request(client, "service/rpc", "ping",
  response_topic: "reply/my_client"
)

# Match the response in your handler:
def handle_mqtt_event(:message, {_topic, payload, packet}, state) do
  if packet.properties[:correlation_data] == state.pending_correlation do
    # This is the response
  end
  state
end
```

### Enhanced Authentication

For brokers that require multi-step authentication (SASL-style), implement `handle_auth/3` in your handler:

```elixir
defmodule MyAuthHandler do
  def handle_mqtt_event(_event, _data, state), do: state

  def handle_auth(0x18, %{authentication_method: "SCRAM-SHA-256", authentication_data: challenge}, state) do
    response = compute_scram_response(challenge, state.credentials)
    {:continue, response, state}
  end

  def handle_auth(_reason_code, _props, state) do
    {:ok, state}
  end
end
```

Include `authentication_method` in connect properties to initiate enhanced auth:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "my_client",
  protocol_version: 5,
  connect_properties: %{authentication_method: "SCRAM-SHA-256", authentication_data: initial_data},
  handler: MyAuthHandler,
  handler_state: %{credentials: my_creds}
)
```

The `authentication_method` is what opts the connection into enhanced
authentication. A broker is not allowed to send AUTH to a client that did not
include it (MQTT-4.12.0-7), so if one arrives anyway the client treats it as a
Protocol Error rather than answering it: during the handshake the connect
attempt fails with `{:protocol_error, :unexpected_auth}`; on a live connection
the client sends DISCONNECT `0x82`, closes, and the handler receives
`{:disconnected, {:protocol_error, :unexpected_auth}}`.

### Server-Negotiated Settings

The client automatically applies MQTT 5.0 CONNACK properties from the broker:

| Property | Behavior |
|----------|----------|
| `server_keep_alive` | Overrides the client's keepalive timer |
| `assigned_client_identifier` | Replaces the client's ID when connecting with empty `client_id` |
| `maximum_packet_size` | Enforced on outgoing packets; oversized sends return `{:error, :packet_too_large}` |
| `receive_maximum` | Limits concurrent in-flight QoS 1/2 publishes |
| `maximum_qos` | Enforced on outgoing publishes: a higher `:qos` returns `{:error, :qos_not_supported}` instead of being lowered silently (MQTT-3.2.2-11). Absent = QoS 2 allowed |
| `retain_available` | When `false`, `publish(..., retain: true)` returns `{:error, :retain_not_supported}` (MQTT-3.2.2-14). Absent = retain allowed |
| `server_reference` | Logged on CONNACK rejection or server DISCONNECT (for redirect) |

All of these are per-connection: every CONNACK replaces the previous values,
so a reconnect to a broker with different limits picks them up.

The client tells the broker its own limits the same way, in CONNECT (v5):
a Receive Maximum of 100 and its `:max_packet_size` (1 MiB by default),
unless `connect_properties` sets them — a `maximum_packet_size` above the
enforced cap is lowered to it, since advertising more would invite packets
the client then refuses.

### Publishing with Properties

```elixir
MqttX.Client.publish(client, "events/alert", payload,
  qos: 1,
  properties: %{
    message_expiry_interval: 3600,
    content_type: "application/json"
  }
)
```

Or let a payload codec set `content_type` and `payload_format_indicator` for you and encode the term as well — `codec: MqttX.Payload.JSON` with a map as the payload. See [Publishing with a codec](codec.md#publishing-with-a-codec).

## Connect Options

| Option | Description | Default |
|--------|-------------|---------|
| `:host` | Broker hostname | *required* |
| `:port` | Broker port | `1883` / `8883` / `8083` / `8084` |
| `:client_id` | Client identifier | *required* |
| `:username` | Authentication username | `nil` |
| `:password` | Authentication password | `nil` |
| `:clean_session` | Start fresh session | `true` |
| `:keepalive` | Keep-alive interval (seconds) | `60` |
| `:await_connect` | Block until the first CONNACK resolves (see [Basic Connection](#basic-connection)) | `false` |
| `:protocol_version` | MQTT protocol level: `3`, `4` (3.1.1) or `5` | `5` |
| `:transport` | `:tcp`, `:ssl`, `:ws`, or `:wss` | `:tcp` |
| `:ssl_opts` | SSL options, merged **over** the secure baseline (see [TLS/SSL](#tls-ssl)) | `[]` |
| `:ws_path` | WebSocket path for `:ws` or `:wss` | `"/mqtt"` |
| `:proxy` | HTTP CONNECT proxy, e.g. `[host: "proxy.corp", port: 3128, auth: {"u", "p"}]` | `nil` |
| `:max_inflight` | Max pending QoS 1/2 messages | `100` |
| `:max_packet_size` | Reject inbound packets declaring more than this (`:infinity` disables) | `1 MiB` |
| `:will_topic` / `:will_payload` / `:will_qos` / `:will_retain` / `:will_properties` | Last Will & Testament (`:will_qos` must be 0, 1 or 2 — anything else raises `ArgumentError`) | `nil` / `""` / `0` / `false` / `%{}` |
| `:connect_properties` | MQTT 5.0 CONNECT properties (e.g. `%{session_expiry_interval: 3600}`) | `%{}` |
| `:session_store` | Session store module | `nil` |
| `:handler` | Callback module for messages | `nil` |
| `:handler_state` | Initial handler state | `nil` |

Unacknowledged QoS 1/2 publishes are held until the broker acknowledges them
and re-sent only when a session is resumed after a reconnect (MQTT §4.4) —
never on a live connection, where TCP already guarantees delivery and a
missing acknowledgement means the broker is slow or gone (which the
keep-alive detects). `:retry_interval` is deprecated and ignored since
0.12.0.

---

← Back to the [documentation index](../README.md#guides)
