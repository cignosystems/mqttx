# Getting Started

This guide walks you through setting up MqttX as a client, a server, or a standalone packet codec.

## Installation

Add `mqttx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mqttx, "~> 0.11.0"},

    # Pick a transport for the server (optional)
    {:thousand_island, "~> 1.4"},  # or {:ranch, "~> 2.2"}
    # WebSocket transport (optional)
    {:bandit, "~> 1.6"},
    {:websock_adapter, "~> 0.5 or ~> 0.6"},

    # Payload codecs (optional)
    {:protox, "~> 2.0"}
  ]
end
```

The core codec has **zero external dependencies** - you only need a transport adapter if you're running the server.

## Connect to a Broker

Incoming messages are pushed to a handler module, so define one first —
without a `:handler` the client connects but you never see anything arrive:

```elixir
defmodule MyApp.Handler do
  require Logger

  def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
    Logger.info("got #{payload} on #{Enum.join(topic, "/")}")
    state
  end

  # Catch-all so other events (:connected, :disconnected, :publish_error)
  # don't raise
  def handle_mqtt_event(_event, _data, state), do: state
end
```

Then connect and use it:

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client",
  handler: MyApp.Handler,
  handler_state: %{},
  # connect/1 is asynchronous by default; this blocks until the session is
  # live so the calls below work inline
  await_connect: true
)

# Subscribe to a topic (returns {:ok, granted_qos_list})
{:ok, [1]} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

# Publish to our own subscription — the handler above logs it
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

# Disconnect
:ok = MqttX.Client.disconnect(client)
```

`topic` arrives as a list of segments (`["sensors", "temp"]`), not a string.

See the [Client Guide](client.md) for TLS, the HTTP proxy option, session
persistence, automatic resubscription, and `use MqttX`.

## Run an MQTT Server

Create a handler module:

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  @impl true
  def init(_opts), do: %{}

  @impl true
  def handle_connect(client_id, _credentials, state) do
    IO.puts("Connected: #{client_id}")
    {:ok, state}
  end

  @impl true
  def handle_publish(topic, payload, _opts, state) do
    IO.puts("#{inspect(topic)}: #{payload}")
    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state) do
    {:ok, Enum.map(topics, & &1.qos), state}
  end

  @impl true
  def handle_disconnect(_reason, _state), do: :ok
end
```

Start it:

```elixir
{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

See the [Server Guide](server.md) for transport adapters, topic routing, and retained messages.

## Use the Codec Standalone

The packet codec works without a server or client:

```elixir
# Encode
packet = %{type: :publish, topic: "test/topic", payload: "hello", qos: 0, retain: false}
{:ok, binary} = MqttX.Packet.Codec.encode(4, packet)

# Decode
{:ok, {decoded, _rest}} = MqttX.Packet.Codec.decode(4, binary)
```

See the [Codec & Payloads Guide](codec.md) for payload codecs and protocol details.

## What's Next?

- [Client Guide](client.md) - TLS/SSL, session persistence, QoS, message handling
- [Server Guide](server.md) - Transport adapters, topic routing, will messages
- [Codec & Payloads](codec.md) - Standalone codec, JSON/Protobuf/Raw payloads
- [Telemetry](telemetry.md) - Observability and metrics
- [Performance](performance.md) - Capacity planning per instance size, VM/OS tuning, architecture decisions
- [Why MQTT for IoT](why-mqtt-for-iot.md) - Protocol comparison, cellular data budgets, and how MqttX compares to other Elixir MQTT libraries

---

← Back to the [documentation index](../README.md#guides)
