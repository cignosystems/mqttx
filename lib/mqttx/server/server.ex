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

  @doc """
  Handle an incoming PUBLISH message.

  Called when a client publishes a message.
  """
  @callback handle_publish(topic(), payload(), publish_opts(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc """
  Handle a SUBSCRIBE request.

  Returns the list of granted QoS values for each topic.
  """
  @callback handle_subscribe([subscribe_topic()], state()) ::
              {:ok, [0 | 1 | 2], state()}

  @doc """
  Handle client disconnection.

  Called when the client disconnects or the connection is closed.
  """
  @callback handle_disconnect(reason :: term(), state()) :: :ok

  @doc """
  Handle an UNSUBSCRIBE request.
  """
  @callback handle_unsubscribe([topic()], state()) :: {:ok, state()}

  @doc """
  Handle a PUBACK for QoS 1 messages.
  """
  @callback handle_puback(packet_id :: non_neg_integer(), state()) :: {:ok, state()}

  @optional_callbacks [handle_unsubscribe: 2, handle_puback: 2]

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

      defoverridable handle_unsubscribe: 2, handle_puback: 2
    end
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
