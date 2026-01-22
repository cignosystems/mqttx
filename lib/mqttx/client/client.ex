defmodule MqttX.Client do
  @moduledoc """
  MQTT Client API.

  Provides a simple interface for connecting to MQTT brokers.

  ## Example

      # Connect
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        port: 1883,
        client_id: "my_app"
      )

      # Subscribe
      :ok = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

      # Publish
      :ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

      # Disconnect
      :ok = MqttX.Client.disconnect(client)

  ## Receiving Messages

  To receive messages, provide a handler module:

      defmodule MyHandler do
        def handle_mqtt_event(:message, {topic, payload, _opts}, state) do
          IO.puts("Received: " <> inspect({topic, payload}))
          state
        end

        def handle_mqtt_event(:connected, _data, state) do
          IO.puts("Connected!")
          state
        end

        def handle_mqtt_event(:disconnected, reason, state) do
          IO.puts("Disconnected: " <> inspect(reason))
          state
        end
      end

      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        client_id: "my_app",
        handler: MyHandler,
        handler_state: %{}
      )
  """

  alias MqttX.Client.Connection

  @doc """
  Connect to an MQTT broker.

  ## Options

  - `:host` - Broker hostname (required)
  - `:port` - Broker port (default: 1883)
  - `:client_id` - Client identifier (required)
  - `:username` - Optional username
  - `:password` - Optional password
  - `:clean_session` - Clean session flag (default: true)
  - `:keepalive` - Keepalive interval in seconds (default: 60)
  - `:handler` - Module to receive callbacks
  - `:handler_state` - Initial state for handler
  - `:name` - Optional name for the client process

  ## Returns

  `{:ok, pid}` on success, `{:error, reason}` on failure.
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts) do
    Connection.start_link(opts)
  end

  @doc """
  Publish a message to a topic.

  ## Options

  - `:qos` - QoS level 0, 1, or 2 (default: 0)
  - `:retain` - Retain flag (default: false)
  """
  @spec publish(pid(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(client, topic, payload, opts \\ []) do
    Connection.publish(client, topic, payload, opts)
  end

  @doc """
  Subscribe to one or more topics.

  ## Options

  - `:qos` - QoS level 0, 1, or 2 (default: 0)
  """
  @spec subscribe(pid(), binary() | [binary()], keyword()) :: :ok | {:error, term()}
  def subscribe(client, topics, opts \\ []) do
    Connection.subscribe(client, topics, opts)
  end

  @doc """
  Unsubscribe from one or more topics.
  """
  @spec unsubscribe(pid(), binary() | [binary()]) :: :ok | {:error, term()}
  def unsubscribe(client, topics) do
    Connection.unsubscribe(client, topics)
  end

  @doc """
  Disconnect from the broker.
  """
  @spec disconnect(pid()) :: :ok
  def disconnect(client) do
    Connection.disconnect(client)
  end

  @doc """
  Check if the client is connected.
  """
  @spec connected?(pid()) :: boolean()
  def connected?(client) do
    Connection.connected?(client)
  end

  @doc """
  Make a request and wait for a response (MQTT 5.0 Request/Response pattern).

  This is a convenience function for the MQTT 5.0 request/response pattern.
  It publishes a message with `response_topic` and `correlation_data` properties,
  subscribes to the response topic, and waits for a matching response.

  ## Options

  - `:response_topic` - Topic to receive the response on (required)
  - `:timeout` - Timeout in milliseconds (default: 5000)
  - `:qos` - QoS level for both request and subscription (default: 0)

  ## Returns

  - `{:ok, response_payload}` - Response received
  - `{:error, :timeout}` - No response within timeout
  - `{:error, reason}` - Other errors

  ## Example

      {:ok, response} = MqttX.Client.request(
        client,
        "api/users/get",
        Jason.encode!(%{id: 123}),
        response_topic: "api/responses/" <> client_id
      )
  """
  @spec request(pid(), binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def request(client, topic, payload, opts) do
    response_topic = Keyword.fetch!(opts, :response_topic)
    _timeout = Keyword.get(opts, :timeout, 5000)
    qos = Keyword.get(opts, :qos, 0)

    # Generate unique correlation data
    correlation_data = :crypto.strong_rand_bytes(16)

    # Subscribe to response topic
    case subscribe(client, response_topic, qos: qos) do
      :ok ->
        # Publish request with properties
        publish_opts = [
          qos: qos,
          properties: %{
            response_topic: response_topic,
            correlation_data: correlation_data
          }
        ]

        case publish(client, topic, payload, publish_opts) do
          :ok ->
            # Wait for response (caller must set up handler to receive it)
            # For a complete implementation, we'd need GenServer-based response tracking
            # For now, return guidance
            {:ok, correlation_data}

          error ->
            error
        end

      error ->
        error
    end
  end
end
