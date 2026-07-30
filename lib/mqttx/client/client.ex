defmodule MqttX.Client do
  @moduledoc """
  MQTT Client API.

  Provides a simple interface for connecting to MQTT brokers.

  ## Example

      # Connect
      # `await_connect: true` blocks until the session is live, so the calls
      # below work inline. Without it, connect/1 returns immediately and these
      # would get {:error, :not_connected} — see "Connection is asynchronous".
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        port: 1883,
        client_id: "my_app",
        await_connect: true
      )

      # Subscribe (returns {:ok, granted_qos_list})
      {:ok, _granted} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)

      # Publish
      :ok = MqttX.Client.publish(client, "sensors/temp", "25.5")

      # Disconnect
      :ok = MqttX.Client.disconnect(client)

  ## Receiving Messages

  To receive messages, provide a handler module:

      defmodule MyHandler do
        def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
          # topic is a list of segments, e.g. ["sensors", "room1", "temp"]
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

        def handle_mqtt_event(:publish_error, {_topic, _packet_id, reason_code}, state) do
          IO.puts("Broker rejected publish: " <> inspect(reason_code))
          state
        end

        # Catch-all so future event types don't raise
        def handle_mqtt_event(_event, _data, state), do: state
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
  Connect to an MQTT broker with supervision.

  Starts the connection under `MqttX.Client.Supervisor`, providing
  automatic restart on crash. The connection is registered in
  `MqttX.ClientRegistry` for lookup by `client_id`.

  Accepts the same options as `connect/1`.

  ## Example

      {:ok, pid} = MqttX.Client.connect_supervised(
        host: "localhost",
        port: 1883,
        client_id: "my_client"
      )
  """
  @spec connect_supervised(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect_supervised(opts) do
    MqttX.Client.Supervisor.start_child(opts)
  end

  @doc """
  List all registered client connections.

  Returns a list of `{client_id, pid, metadata}` tuples for all connections
  registered in `MqttX.ClientRegistry`.

  ## Example

      MqttX.Client.list()
      #=> [{"my_client", #PID<0.123.0>, %{host: "localhost", port: 1883}}]
  """
  @spec list() :: [{binary(), pid(), map()}]
  def list do
    Registry.select(MqttX.ClientRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Look up a client connection by its `client_id`.

  Returns `{pid, metadata}` if found, or `nil` if not registered.

  ## Example

      MqttX.Client.whereis("my_client")
      #=> {#PID<0.123.0>, %{host: "localhost", port: 1883}}
  """
  @spec whereis(binary()) :: {pid(), map()} | nil
  def whereis(client_id) do
    case Registry.lookup(MqttX.ClientRegistry, client_id) do
      [{pid, meta}] -> {pid, meta}
      [] -> nil
    end
  end

  @doc """
  Connect to an MQTT broker.

  ## Options

  - `:host` - Broker hostname (required)
  - `:port` - Broker port (default: 1883 TCP / 8883 SSL / 8083 WS / 8084 WSS)
  - `:client_id` - Client identifier (required)
  - `:username` - Optional username
  - `:password` - Optional password
  - `:clean_session` - Clean session flag (default: true)
  - `:keepalive` - Keepalive interval in seconds (default: 60)
  - `:protocol_version` - `3`, `4` (3.1.1) or `5` (default: 5)
  - `:handler` - Module to receive callbacks
  - `:handler_state` - Initial state for handler
  - `:name` - Optional name for the client process

  ### Transport

  - `:transport` - `:tcp`, `:ssl`, `:ws` or `:wss` (default: `:tcp`)
  - `:ssl_opts` - SSL options for `:ssl`/`:wss`, merged **over** a secure
    baseline (`verify: :verify_peer` against the OS trust store, SNI, HTTPS
    hostname checking, TLS 1.2/1.3). Pass `[verify: :verify_none]` to opt out
    deliberately; it is logged as a warning.
  - `:ws_path` - WebSocket path for `:ws`/`:wss` (default: `"/mqtt"`)
  - `:proxy` - Tunnel through an HTTP `CONNECT` proxy, e.g.
    `[host: "proxy.corp", port: 3128, auth: {"user", "pass"}]`. Works for all
    transports; `:port` defaults to 3128 and `:auth` (Basic) is optional. TLS
    is negotiated with the broker through the tunnel.

  ### Reliability and limits

  - `:retry_interval` - QoS 1/2 retry interval in ms (default: 5000)
  - `:max_inflight` - Max pending QoS 1/2 messages (default: 100)
  - `:max_packet_size` - Reject inbound packets declaring more than this
    (default: 1 MiB; `:infinity` disables)
  - `:session_store` - Session store module or `{module, opts}`
  - `:connect_properties` - MQTT 5.0 CONNECT properties, e.g.
    `%{session_expiry_interval: 3600, receive_maximum: 20}`

  ### Last Will & Testament

  - `:will_topic`, `:will_payload`, `:will_qos`, `:will_retain`,
    `:will_properties`

  ## Returns

  `{:ok, pid}` on success, `{:error, reason}` on failure — including
  `{:error, {:missing_option, :host | :client_id}}` when a required option is
  absent.

  ## Connection is asynchronous

  `connect/1` returns as soon as the client process starts — **the session is
  not yet live**. The CONNECT/CONNACK handshake happens in the background so
  that a client can be started before the broker is reachable (a device
  booting before its network, a broker still starting up) and keep retrying
  with backoff.

  This means `subscribe/3` and `publish/4` called immediately after
  `connect/1` will return `{:error, :not_connected}`. Wait for readiness in
  one of these ways:

      # 1. Act on the :connected event (recommended for long-lived clients)
      def handle_mqtt_event(:connected, _info, state) do
        MqttX.Client.subscribe(self(), "sensors/#", qos: 1)
        state
      end

      # 2. Block until the first attempt resolves (handy in scripts and tests)
      {:ok, client} = MqttX.Client.connect(host: "broker", client_id: "c",
                                           await_connect: true)
      # session is live here, or {:error, reason} was returned

  With `await_connect: true`, a failed first attempt returns
  `{:error, reason}` (for example `:econnrefused`, a TLS failure, or
  `{:connack_error, code, info}`) and the client is stopped rather than left
  retrying.
  """
  @spec connect(keyword()) :: GenServer.on_start() | {:error, term()}
  def connect(opts) do
    {await?, start_opts} = Keyword.pop(opts, :await_connect, false)

    with {:ok, pid} <- Connection.start_link(start_opts) do
      if await? do
        case Connection.await_connect(pid) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            # Don't leave an orphan retrying in the background when the caller
            # was told the connection failed.
            _ = GenServer.stop(pid, :normal, 1_000)
            {:error, reason}
        end
      else
        {:ok, pid}
      end
    end
  end

  @doc """
  Publish a message to a topic.

  ## Options

  - `:qos` - QoS level 0, 1, or 2 (default: 0)
  - `:retain` - Retain flag (default: false)
  - `:properties` - PUBLISH properties map (MQTT 5.0), e.g.
    `%{message_expiry_interval: 60, response_topic: "replies/1",
    correlation_data: "req-42", user_properties: [{"k", "v"}]}`

  `:ok` means the packet was written to the socket; for QoS 1/2 the
  broker's acknowledgment is tracked in the background (rejections surface
  via `handle_mqtt_event(:publish_error, {topic, packet_id, reason_code}, state)`).
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
  @spec subscribe(pid(), binary() | [binary()], keyword()) ::
          {:ok, [integer()]} | {:error, term()}
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

  Asynchronous: the returned `:ok` acknowledges the request, not that the
  DISCONNECT packet has been sent — the client process sends it and stops
  shortly after.

  ## Options (MQTT 5.0)

  - `:reason_code` - Disconnect reason code (default: 0x00 Normal)
  - `:properties` - Disconnect properties map, e.g. `%{session_expiry_interval: 0}`
  """
  @spec disconnect(pid(), keyword()) :: :ok
  def disconnect(client, opts \\ []) do
    Connection.disconnect(client, opts)
  end

  @doc """
  Check if the client is connected.
  """
  @spec connected?(pid()) :: boolean()
  def connected?(client) do
    Connection.connected?(client)
  end

  @doc """
  Set up an MQTT 5.0 Request/Response exchange.

  Subscribes to the `response_topic`, then publishes a message with
  `response_topic` and `correlation_data` properties set. Returns the
  generated `correlation_data` so the caller can match incoming responses
  in their handler.

  This is a setup helper, not a blocking RPC call. Use `handle_mqtt_event/3`
  in your handler to match responses by `correlation_data`.

  ## Options

  - `:response_topic` - Topic to receive the response on (required)
  - `:qos` - QoS level for both request and subscription (default: 0)

  ## Returns

  - `{:ok, correlation_data}` - Request sent, use this to match the response
  - `{:error, reason}` - Subscribe or publish failed

  ## Example

      {:ok, correlation_data} = MqttX.Client.request(
        client,
        "api/users/get",
        Jason.encode!(%{id: 123}),
        response_topic: "api/responses/" <> client_id
      )

      # In your handler:
      def handle_mqtt_event(:message, {_topic, payload, packet}, state) do
        if packet.properties[:correlation_data] == state.pending_correlation do
          # This is the response
        end
        state
      end
  """
  @spec request(pid(), binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def request(client, topic, payload, opts) do
    response_topic = Keyword.fetch!(opts, :response_topic)
    qos = Keyword.get(opts, :qos, 0)

    # Generate unique correlation data for matching responses
    correlation_data = :crypto.strong_rand_bytes(16)

    # Subscribe to response topic, then publish the request
    case subscribe(client, response_topic, qos: qos) do
      {:ok, _granted_qos} ->
        publish_opts = [
          qos: qos,
          properties: %{
            response_topic: response_topic,
            correlation_data: correlation_data
          }
        ]

        case publish(client, topic, payload, publish_opts) do
          :ok -> {:ok, correlation_data}
          error -> error
        end

      error ->
        error
    end
  end
end
