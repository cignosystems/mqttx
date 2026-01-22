defmodule MqttX.Telemetry do
  @moduledoc """
  Telemetry events for MqttX.

  MqttX emits telemetry events at key points in the client and server lifecycle.
  You can attach handlers to these events to collect metrics, log events, or
  integrate with your observability stack.

  ## Event Naming Convention

  All events are prefixed with `[:mqttx, ...]`. Client events use `[:mqttx, :client, ...]`
  and server events use `[:mqttx, :server, ...]`.

  ## Client Events

  ### `[:mqttx, :client, :connect, :start]`
  Emitted when a client starts connecting to a broker.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{host: binary(), port: integer(), client_id: binary(), transport: :tcp | :ssl}`

  ### `[:mqttx, :client, :connect, :stop]`
  Emitted when a client successfully connects.

  - Measurements: `%{duration: integer()}` (in native time units)
  - Metadata: `%{host: binary(), port: integer(), client_id: binary()}`

  ### `[:mqttx, :client, :connect, :exception]`
  Emitted when a client fails to connect.

  - Measurements: `%{duration: integer()}`
  - Metadata: `%{host: binary(), port: integer(), client_id: binary(), reason: term()}`

  ### `[:mqttx, :client, :disconnect]`
  Emitted when a client disconnects.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), reason: atom()}`

  ### `[:mqttx, :client, :publish, :start]`
  Emitted when a client starts publishing a message.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), topic: binary(), qos: 0..2, payload_size: integer()}`

  ### `[:mqttx, :client, :publish, :stop]`
  Emitted when a publish completes (QoS 0) or is acknowledged (QoS 1/2).

  - Measurements: `%{duration: integer()}`
  - Metadata: `%{client_id: binary(), topic: binary(), qos: 0..2}`

  ### `[:mqttx, :client, :subscribe]`
  Emitted when a client subscribes to topics.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), topics: list()}`

  ### `[:mqttx, :client, :message]`
  Emitted when a client receives a message.

  - Measurements: `%{system_time: integer(), payload_size: integer()}`
  - Metadata: `%{client_id: binary(), topic: binary(), qos: 0..2}`

  ## Server Events

  ### `[:mqttx, :server, :client_connect, :start]`
  Emitted when a client starts connecting to the server.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), protocol_version: integer()}`

  ### `[:mqttx, :server, :client_connect, :stop]`
  Emitted when a client successfully connects to the server.

  - Measurements: `%{duration: integer()}`
  - Metadata: `%{client_id: binary(), protocol_version: integer()}`

  ### `[:mqttx, :server, :client_connect, :exception]`
  Emitted when a client connection is rejected.

  - Measurements: `%{duration: integer()}`
  - Metadata: `%{client_id: binary(), reason_code: integer()}`

  ### `[:mqttx, :server, :client_disconnect]`
  Emitted when a client disconnects from the server.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), reason: atom()}`

  ### `[:mqttx, :server, :publish]`
  Emitted when the server receives a PUBLISH packet.

  - Measurements: `%{system_time: integer(), payload_size: integer()}`
  - Metadata: `%{client_id: binary(), topic: binary(), qos: 0..2}`

  ### `[:mqttx, :server, :subscribe]`
  Emitted when a client subscribes.

  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{client_id: binary(), topics: list()}`

  ## Example Usage

  ```elixir
  # Attach a handler in your application startup
  :telemetry.attach_many(
    "mqttx-logger",
    [
      [:mqttx, :client, :connect, :stop],
      [:mqttx, :client, :disconnect],
      [:mqttx, :server, :publish]
    ],
    &MyApp.TelemetryHandler.handle_event/4,
    nil
  )
  ```
  """

  @doc """
  Execute a span event with start/stop/exception.

  Returns the result of the function.
  """
  @spec span(list(atom()), map(), (-> result)) :: result when result: var
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_function(fun, 0) do
    :telemetry.span(event_prefix, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  @doc """
  Emit a telemetry event with the current system time.
  """
  @spec emit(list(atom()), map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new(measurements, :system_time, System.system_time())
    :telemetry.execute(event, measurements, metadata)
  end

  # ============================================================================
  # Client Events
  # ============================================================================

  @doc false
  def client_connect_start(metadata) do
    emit([:mqttx, :client, :connect, :start], %{}, metadata)
  end

  @doc false
  def client_connect_stop(duration, metadata) do
    emit([:mqttx, :client, :connect, :stop], %{duration: duration}, metadata)
  end

  @doc false
  def client_connect_exception(duration, metadata) do
    emit([:mqttx, :client, :connect, :exception], %{duration: duration}, metadata)
  end

  @doc false
  def client_disconnect(metadata) do
    emit([:mqttx, :client, :disconnect], %{}, metadata)
  end

  @doc false
  def client_publish_start(metadata) do
    emit([:mqttx, :client, :publish, :start], %{}, metadata)
  end

  @doc false
  def client_publish_stop(duration, metadata) do
    emit([:mqttx, :client, :publish, :stop], %{duration: duration}, metadata)
  end

  @doc false
  def client_subscribe(metadata) do
    emit([:mqttx, :client, :subscribe], %{}, metadata)
  end

  @doc false
  def client_message(payload_size, metadata) do
    emit([:mqttx, :client, :message], %{payload_size: payload_size}, metadata)
  end

  # ============================================================================
  # Server Events
  # ============================================================================

  @doc false
  def server_client_connect_start(metadata) do
    emit([:mqttx, :server, :client_connect, :start], %{}, metadata)
  end

  @doc false
  def server_client_connect_stop(duration, metadata) do
    emit([:mqttx, :server, :client_connect, :stop], %{duration: duration}, metadata)
  end

  @doc false
  def server_client_connect_exception(duration, metadata) do
    emit([:mqttx, :server, :client_connect, :exception], %{duration: duration}, metadata)
  end

  @doc false
  def server_client_disconnect(metadata) do
    emit([:mqttx, :server, :client_disconnect], %{}, metadata)
  end

  @doc false
  def server_publish(payload_size, metadata) do
    emit([:mqttx, :server, :publish], %{payload_size: payload_size}, metadata)
  end

  @doc false
  def server_subscribe(metadata) do
    emit([:mqttx, :server, :subscribe], %{}, metadata)
  end
end
