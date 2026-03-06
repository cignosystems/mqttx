# Client Guide

`MqttX.Client` provides a GenServer-based MQTT client with automatic reconnection and exponential backoff.

## Basic Connection

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client",
  username: "user",        # optional
  password: "secret"       # optional
)

:ok = MqttX.Client.subscribe(client, "sensors/#", qos: 1)
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")
:ok = MqttX.Client.disconnect(client)
```

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

## TLS/SSL

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  port: 8883,
  client_id: "secure_client",
  transport: :ssl,
  ssl_opts: [
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    server_name_indication: ~c"broker.example.com"
  ]
)
```

When `:transport` is `:ssl`, the default port changes to `8883`.

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

The handler receives three event types:

| Event | Data | Description |
|-------|------|-------------|
| `:message` | `{topic, payload, packet}` | Incoming PUBLISH message |
| `:connected` | `%{properties: props}` | Connection established (props contains CONNACK properties) |
| `:disconnected` | reason | Connection lost (may be `{:server_disconnect, code, %{server_reference: ref}}`) |

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

  def handle_auth(0x18, %{auth_method: "SCRAM-SHA-256", auth_data: challenge}, state) do
    response = compute_scram_response(challenge, state.credentials)
    {:continue, response, state}
  end

  def handle_auth(_reason_code, _props, state) do
    {:ok, state}
  end
end
```

Include `auth_method` in connect properties to initiate enhanced auth:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "my_client",
  protocol_version: 5,
  connect_properties: %{auth_method: "SCRAM-SHA-256", auth_data: initial_data},
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
| `:port` | Broker port | `1883` / `8883` (SSL) |
| `:client_id` | Client identifier | *required* |
| `:username` | Authentication username | `nil` |
| `:password` | Authentication password | `nil` |
| `:clean_session` | Start fresh session | `true` |
| `:keepalive` | Keep-alive interval (seconds) | `60` |
| `:transport` | `:tcp` or `:ssl` | `:tcp` |
| `:ssl_opts` | SSL options for `:ssl` transport | `[]` |
| `:retry_interval` | QoS retry interval (ms) | `5000` |
| `:max_inflight` | Max pending QoS 1/2 messages | `100` |
| `:connect_properties` | MQTT 5.0 CONNECT properties map | `%{}` |
| `:session_store` | Session store module | `nil` |
| `:handler` | Callback module for messages | `nil` |
| `:handler_state` | Initial handler state | `nil` |
