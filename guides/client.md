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

### Connection is asynchronous by default

Without `await_connect: true`, `connect/1` returns as soon as the client
process starts — *before* the CONNECT/CONNACK handshake completes — so a
`subscribe` or `publish` issued immediately afterwards returns
`{:error, :not_connected}`. That default exists so a client can be started
before its broker is reachable and keep retrying with backoff, which is the
normal case for devices and for apps that boot alongside their broker.

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
| `:message` | `{topic, payload, packet}` | Incoming PUBLISH message. `topic` is a list of segments |
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

### Server-Negotiated Settings

The client automatically applies MQTT 5.0 CONNACK properties from the broker:

| Property | Behavior |
|----------|----------|
| `server_keep_alive` | Overrides the client's keepalive timer |
| `assigned_client_identifier` | Replaces the client's ID when connecting with empty `client_id` |
| `maximum_packet_size` | Enforced on outgoing packets; oversized sends return `{:error, :packet_too_large}` |
| `receive_maximum` | Limits concurrent in-flight QoS 1/2 publishes |
| `server_reference` | Logged on CONNACK rejection or server DISCONNECT (for redirect) |

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
| `:retry_interval` | QoS retry interval (ms) | `5000` |
| `:max_inflight` | Max pending QoS 1/2 messages | `100` |
| `:max_packet_size` | Reject inbound packets declaring more than this (`:infinity` disables) | `1 MiB` |
| `:will_topic` / `:will_payload` / `:will_qos` / `:will_retain` / `:will_properties` | Last Will & Testament | `nil` / `""` / `0` / `false` / `%{}` |
| `:connect_properties` | MQTT 5.0 CONNECT properties (e.g. `%{session_expiry_interval: 3600}`) | `%{}` |
| `:session_store` | Session store module | `nil` |
| `:handler` | Callback module for messages | `nil` |
| `:handler_state` | Initial handler state | `nil` |

---

← Back to the [documentation index](../README.md#guides)
