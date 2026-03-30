defmodule MqttX.Server do
  @moduledoc """
  MQTT Server behaviour.

  Implement this behaviour to create a custom MQTT server/broker.

  ## Example

      defmodule MyApp.MqttHandler do
        use MqttX.Server

        @impl true
        def init(_opts) do
          %{subscriptions: %{}}
        end

        @impl true
        def handle_connect(client_id, credentials, state) do
          IO.puts("Client connected: " <> client_id)
          {:ok, state}
        end

        @impl true
        def handle_publish(topic, payload, opts, state) do
          IO.puts("Received: " <> inspect({topic, payload}))
          {:ok, state}
        end

        @impl true
        def handle_subscribe(topics, state) do
          qos_list = Enum.map(topics, fn t -> t.qos end)
          {:ok, qos_list, state}
        end

        @impl true
        def handle_disconnect(reason, state) do
          IO.puts("Client disconnected: " <> inspect(reason))
          :ok
        end
      end

      # Start the server
      MqttX.Server.start_link(MyApp.MqttHandler, [],
        transport: MqttX.Transport.ThousandIsland,
        port: 1883
      )

  ## Callbacks

  The following callbacks are required:

  - `init/1` - Initialize handler state
  - `handle_connect/3` - Handle client connection
  - `handle_publish/4` - Handle incoming PUBLISH messages
  - `handle_subscribe/2` - Handle SUBSCRIBE requests
  - `handle_disconnect/2` - Handle client disconnection

  Optional callbacks:

  - `handle_unsubscribe/2` - Handle UNSUBSCRIBE requests
  - `handle_puback/2` - Handle PUBACK for QoS 1 messages
  """

  @type client_id :: binary()
  @type credentials :: %{username: binary() | nil, password: binary() | nil}
  @type topic :: MqttX.Topic.normalized_topic()
  @type payload :: binary()
  @type publish_opts :: %{
          qos: 0 | 1 | 2,
          retain: boolean(),
          dup: boolean(),
          packet_id: non_neg_integer() | nil,
          properties: map()
        }
  @type subscribe_topic :: %{
          topic: topic(),
          qos: 0 | 1 | 2,
          no_local: boolean(),
          retain_as_published: boolean(),
          retain_handling: 0 | 1 | 2
        }
  @type reason_code :: non_neg_integer()
  @type state :: term()

  @doc """
  Initialize the handler state.

  Called when starting the server.
  """
  @callback init(opts :: term()) :: state()

  @doc """
  Handle a client connection.

  Called when a client sends a CONNECT packet.

  Return `{:ok, new_state}` to accept the connection,
  or `{:error, reason_code, new_state}` to reject.
  """
  @callback handle_connect(client_id(), credentials(), state()) ::
              {:ok, state()} | {:error, reason_code(), state()}

  @type connect_info :: %{protocol_version: 3 | 4 | 5, keep_alive: non_neg_integer()}

  @doc """
  Handle a client connection with connection metadata.

  Same as `handle_connect/3` but receives an additional `connect_info` map
  with protocol metadata:

    - `protocol_version` — 3 (MQTT 3.1), 4 (MQTT 3.1.1), or 5 (MQTT 5.0)
    - `keep_alive` — client's requested keepalive in seconds

  If both `handle_connect/4` and `handle_connect/3` are defined,
  `handle_connect/4` takes precedence.
  """
  @callback handle_connect(client_id(), credentials(), connect_info(), state()) ::
              {:ok, state()} | {:error, reason_code(), state()}

  @doc """
  Handle an incoming PUBLISH message.

  Called when a client publishes a message.
  """
  @callback handle_publish(topic(), payload(), publish_opts(), state()) ::
              {:ok, state()}
              | {:error, term(), state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle a SUBSCRIBE request.

  Returns the list of granted QoS values for each topic.
  """
  @callback handle_subscribe([subscribe_topic()], state()) ::
              {:ok, [0 | 1 | 2], state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle client disconnection.

  Called when the client disconnects or the connection is closed.
  """
  @callback handle_disconnect(reason :: term(), state()) :: :ok

  @doc """
  Handle an UNSUBSCRIBE request.
  """
  @callback handle_unsubscribe([topic()], state()) ::
              {:ok, state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle a PUBACK for QoS 1 messages.
  """
  @callback handle_puback(packet_id :: non_neg_integer(), state()) :: {:ok, state()}

  @doc """
  Handle enhanced authentication (MQTT 5.0).

  Called when the server receives an AUTH packet for SASL-style authentication.

  Return values:
  - `{:ok, state}` - Authentication complete, send CONNACK success
  - `{:continue, data, state}` - Send AUTH continue with data, wait for response
  - `{:error, reason_code, state}` - Authentication failed

  ## Example

      def handle_auth("SCRAM-SHA-256", data, state) do
        case verify_scram(data, state) do
          {:ok, _} -> {:ok, state}
          {:continue, challenge} -> {:continue, challenge, state}
          :error -> {:error, 0x87, state}  # Not authorized
        end
      end
  """
  @callback handle_auth(method :: binary(), data :: binary() | nil, state()) ::
              {:ok, state()}
              | {:continue, binary(), state()}
              | {:error, reason_code(), state()}

  @doc """
  Handle custom messages (e.g., from PubSub for outgoing MQTT publishes).

  Return values:
  - `{:ok, state}` - Continue with updated state
  - `{:publish, topic, payload, state}` - Send PUBLISH to client, then continue
  - `{:publish, topic, payload, opts, state}` - Send PUBLISH with QoS/retain options
  - `{:disconnect, reason_code, state}` - Send DISCONNECT and close connection
  - `{:disconnect, reason_code, properties, state}` - Send DISCONNECT with properties and close
  - `{:stop, reason, state}` - Close the connection
  """
  @callback handle_info(message :: term(), state()) ::
              {:ok, state()}
              | {:publish, binary(), binary(), state()}
              | {:publish, binary(), binary(), map(), state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}
              | {:stop, term(), state()}

  @doc """
  Handle session expiry (MQTT 5.0).

  Called when a client's session expires after `session_expiry_interval` seconds
  post-disconnect. Use this to clean up session state (subscriptions, queued messages, etc.).
  """
  @callback handle_session_expired(client_id(), state()) :: :ok

  @optional_callbacks [
    handle_connect: 4,
    handle_unsubscribe: 2,
    handle_puback: 2,
    handle_info: 2,
    handle_auth: 3,
    handle_session_expired: 2
  ]

  @doc """
  Use MqttX.Server to define default implementations.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour MqttX.Server

      @impl true
      def handle_unsubscribe(_topics, state) do
        {:ok, state}
      end

      @impl true
      def handle_puback(_packet_id, state) do
        {:ok, state}
      end

      @impl true
      def handle_info(_message, state) do
        {:ok, state}
      end

      @impl true
      def handle_auth(_method, _data, state) do
        # Default: enhanced auth not supported
        {:error, 0x8C, state}
      end

      @impl true
      def handle_session_expired(_client_id, _state) do
        :ok
      end

      defoverridable handle_unsubscribe: 2,
                     handle_puback: 2,
                     handle_info: 2,
                     handle_auth: 3,
                     handle_session_expired: 2
    end
  end

  @doc """
  Disconnect a client from the server with an MQTT 5.0 reason code.

  Sends a DISCONNECT packet to the client and closes the connection.
  The `pid` is the transport process handling the client connection.

  ## Example

      MqttX.Server.disconnect(client_pid, 0x98)  # Use assigned client identifier
      MqttX.Server.disconnect(client_pid, 0x89, %{reason_string: "Session taken over"})
  """
  @spec disconnect(pid(), reason_code(), map()) :: :ok
  def disconnect(pid, reason_code, properties \\ %{}) do
    send(pid, {:server_disconnect, reason_code, properties})
    :ok
  end

  @doc """
  Start an MQTT server.

  ## Options

  - `:transport` - Transport module (default: `MqttX.Transport.ThousandIsland`)
  - `:port` - Port to listen on (default: 1883)
  - `:name` - Optional name for the server process

  All other options are passed to the transport adapter.
  """
  @spec start_link(module(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(handler, handler_opts, opts \\ []) do
    transport = Keyword.get(opts, :transport, MqttX.Transport.ThousandIsland)
    transport_opts = Keyword.drop(opts, [:name])

    transport.start_link(handler, handler_opts, transport_opts)
  end
end
