# Getting Started

This guide walks you through setting up MqttX as a client, a server, or a standalone packet codec.

## Installation

Add `mqttx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mqttx, "~> 0.9.0"},

    # Pick a transport for the server (optional)
    {:thousand_island, "~> 1.4"},  # or {:ranch, "~> 2.2"}
    # WebSocket transport (optional)
    {:bandit, "~> 1.6"},
    {:websock_adapter, "~> 0.5"},

    # Payload codecs (optional)
    {:protox, "~> 2.0"}
  ]
end
```

The core codec has **zero external dependencies** - you only need a transport adapter if you're running the server.

## Connect to a Broker

```elixir
{:ok, client} = MqttX.Client.connect(
  host: "localhost",
  port: 1883,
  client_id: "my_client"
)

# Subscribe to a topic
:ok = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

# Publish a message
:ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

# Disconnect
:ok = MqttX.Client.disconnect(client)
```

See the [Client Guide](client.md) for TLS, session persistence, and message handling.

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
- [Performance](performance.md) - Scaling to hundreds of thousands of devices, architecture decisions
