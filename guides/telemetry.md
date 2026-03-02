# Telemetry

MqttX emits [`:telemetry`](https://hex.pm/packages/telemetry) events at key points in the client and server lifecycle. Use these to build dashboards, alerts, and debugging tools.

## Client Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:mqttx, :client, :connect, :start]` | `system_time` | `client_id`, `host`, `port`, `transport` |
| `[:mqttx, :client, :connect, :stop]` | `duration` | `client_id`, `host`, `port` |
| `[:mqttx, :client, :connect, :exception]` | `duration` | `client_id`, `host`, `port`, `reason` |
| `[:mqttx, :client, :disconnect]` | `system_time` | `client_id`, `reason` |
| `[:mqttx, :client, :publish, :start]` | `system_time` | `client_id`, `topic`, `qos`, `payload_size` |
| `[:mqttx, :client, :publish, :stop]` | `duration` | `client_id`, `topic`, `qos` |
| `[:mqttx, :client, :subscribe]` | `system_time` | `client_id`, `topics` |
| `[:mqttx, :client, :message]` | `system_time`, `payload_size` | `client_id`, `topic`, `qos` |

The `connect` and `publish` events use the start/stop/exception span pattern. `duration` is in native time units — use `System.convert_time_unit/3` to convert.

## Server Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:mqttx, :server, :client_connect, :start]` | `system_time` | `client_id`, `protocol_version` |
| `[:mqttx, :server, :client_connect, :stop]` | `duration` | `client_id`, `protocol_version` |
| `[:mqttx, :server, :client_connect, :exception]` | `duration` | `client_id`, `reason_code` |
| `[:mqttx, :server, :client_disconnect]` | `system_time` | `client_id`, `reason` |
| `[:mqttx, :server, :publish]` | `system_time`, `payload_size` | `client_id`, `topic`, `qos` |
| `[:mqttx, :server, :subscribe]` | `system_time` | `client_id`, `topics` |

## Attaching Handlers

Attach handlers in your application's `start/2` callback so they're registered before any MQTT connections are made:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    attach_telemetry()

    children = [
      # ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp attach_telemetry do
    :telemetry.attach_many(
      "mqttx-metrics",
      [
        [:mqttx, :client, :connect, :stop],
        [:mqttx, :client, :connect, :exception],
        [:mqttx, :client, :disconnect],
        [:mqttx, :client, :publish, :stop],
        [:mqttx, :client, :message],
        [:mqttx, :server, :client_connect, :stop],
        [:mqttx, :server, :client_disconnect],
        [:mqttx, :server, :publish]
      ],
      &MyApp.MqttxTelemetry.handle_event/4,
      nil
    )
  end
end
```

## Example: Logger Handler

```elixir
defmodule MyApp.MqttxTelemetry do
  require Logger

  def handle_event([:mqttx, :client, :connect, :stop], %{duration: duration}, meta, _config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("[MQTT] Client #{meta.client_id} connected in #{ms}ms")
  end

  def handle_event([:mqttx, :server, :publish], %{payload_size: size}, meta, _config) do
    Logger.debug("[MQTT] #{meta.client_id} published #{size}B to #{meta.topic}")
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
```

## Example: Metrics with `:telemetry_metrics`

If you use [`telemetry_metrics`](https://hex.pm/packages/telemetry_metrics) with a reporter (e.g., `TelemetryMetricsPrometheus` or `TelemetryMetricsStatsd`):

```elixir
defmodule MyApp.Metrics do
  import Telemetry.Metrics

  def metrics do
    [
      # Connection latency histogram
      distribution("mqttx.client.connect.stop.duration",
        unit: {:native, :millisecond},
        tags: [:client_id]
      ),

      # Messages per second
      counter("mqttx.server.publish.system_time",
        tags: [:topic, :qos]
      ),

      # Connected clients gauge (increment on connect, decrement on disconnect)
      counter("mqttx.server.client_connect.stop.system_time",
        tags: [:protocol_version]
      ),
      counter("mqttx.server.client_disconnect.system_time",
        tags: [:reason]
      ),

      # Payload size distribution
      distribution("mqttx.server.publish.payload_size",
        unit: :byte,
        tags: [:topic],
        reporter_options: [buckets: [64, 256, 1024, 4096, 16384]]
      ),

      # Publish latency (QoS 1/2 acknowledgment time)
      distribution("mqttx.client.publish.stop.duration",
        unit: {:native, :millisecond},
        tags: [:qos]
      )
    ]
  end
end
```

See `MqttX.Telemetry` module docs for the complete API reference.
