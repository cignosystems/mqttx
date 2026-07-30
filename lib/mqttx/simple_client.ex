defmodule MqttX.SimpleClient do
  @moduledoc """
  Runtime for `use MqttX` — a module-based MQTT client (GitHub issue #1).

      defmodule MyClient do
        use MqttX

        @impl true
        def init(opts) do
          {:ok, %{count: 0}}
        end

        @impl true
        def handle_message(topic, payload, _packet, state) do
          # Publishing from inside a callback is safe: callbacks run in
          # their own process, not inside the connection.
          publish("replies/" <> Enum.join(topic, "/"), "got it", qos: 1)
          {:ok, %{state | count: state.count + 1}}
        end
      end

      # In a supervision tree:
      children = [
        {MyClient, host: "broker.example.com", client_id: "my-client"}
      ]

  `use MqttX` injects `start_link/1`, `child_spec/1`, and the convenience
  functions `publish/2,3`, `subscribe/1,2`, `unsubscribe/1`, `connected?/0`,
  and `disconnect/0,1` (which address the process registered under the
  module name). Connection options passed to `start_link/1` are the same as
  `MqttX.Client.connect/1`; `:name` overrides the registered name (when you
  do that, use the `MqttX.SimpleClient` functions with your name instead of
  the injected helpers).

  ## Callbacks

  Every callback has a default implementation, so implement only the ones you need.

  - `init(opts)` — build the initial state from the `start_link/1` options.
    Default: `{:ok, %{}}`.
  - `handle_message(topic, payload, packet, state)` — one incoming PUBLISH.
    `topic` is a list of segments.
  - `handle_connected(info, state)` — after CONNACK success (also after
    automatic reconnects); `info` has `:session_present` and `:properties`.
  - `handle_disconnected(reason, state)` — connection lost (an automatic
    reconnect follows unless the broker rejection was fatal).
  - `handle_publish_error(topic, packet_id, reason_code, state)` — broker
    rejected a QoS 1/2 publish.
  - `handle_info(message, state)` — any other message sent to the process.

  Each returns `{:ok, state}` or `{:stop, reason, state}`.
  """

  use GenServer

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()}
  @callback handle_message(MqttX.Topic.normalized_topic(), binary(), map(), state()) ::
              {:ok, state()} | {:stop, term(), state()}
  @callback handle_connected(map(), state()) :: {:ok, state()} | {:stop, term(), state()}
  @callback handle_disconnected(term(), state()) :: {:ok, state()} | {:stop, term(), state()}
  @callback handle_publish_error(term(), integer() | nil, integer(), state()) ::
              {:ok, state()} | {:stop, term(), state()}
  @callback handle_info(term(), state()) :: {:ok, state()} | {:stop, term(), state()}

  defmodule Forwarder do
    @moduledoc false
    def handle_mqtt_event(event, data, %{owner: owner} = handler_state) do
      send(owner, {:__mqttx_event__, event, data})
      handler_state
    end
  end

  # ---------- API (used by the injected helpers) ----------

  def start_link(module, opts) do
    {name, connect_opts} = Keyword.pop(opts, :name, module)
    GenServer.start_link(__MODULE__, {module, connect_opts}, name: name)
  end

  # The process-dictionary key is set in init/1 and identifies THIS process as
  # the wrapper owning `client`. Since user callbacks only ever run on the
  # wrapper process (via dispatch/3), its presence means "a GenServer.call to
  # `server` would be a call to self" — so talk to the connection directly
  # instead of deadlocking.
  def publish(server, topic, payload, opts \\ []) do
    case Process.get(:__mqttx_simple_client__) do
      client when is_pid(client) -> MqttX.Client.publish(client, topic, payload, opts)
      nil -> GenServer.call(server, {:client_op, :publish, [topic, payload, opts]})
    end
  end

  def subscribe(server, topics, opts \\ []) do
    case Process.get(:__mqttx_simple_client__) do
      client when is_pid(client) -> MqttX.Client.subscribe(client, topics, opts)
      nil -> GenServer.call(server, {:client_op, :subscribe, [topics, opts]})
    end
  end

  def unsubscribe(server, topics) do
    case Process.get(:__mqttx_simple_client__) do
      client when is_pid(client) -> MqttX.Client.unsubscribe(client, topics)
      nil -> GenServer.call(server, {:client_op, :unsubscribe, [topics]})
    end
  end

  def connected?(server) do
    case Process.get(:__mqttx_simple_client__) do
      client when is_pid(client) -> MqttX.Client.connected?(client)
      nil -> GenServer.call(server, {:client_op, :connected?, []})
    end
  end

  def disconnect(server, opts \\ []) do
    GenServer.call(server, {:disconnect, opts})
  end

  # ---------- GenServer ----------

  @impl GenServer
  def init({module, opts}) do
    {:ok, user_state} = module.init(opts)

    connect_opts =
      opts
      |> Keyword.drop([:handler, :handler_state])
      |> Keyword.merge(handler: Forwarder, handler_state: %{owner: self()})

    case MqttX.Client.Connection.start_link(connect_opts) do
      {:ok, client} ->
        # Marks this process as the wrapper owning `client`; the injected
        # helpers use it to avoid calling themselves (see publish/4).
        Process.put(:__mqttx_simple_client__, client)
        ref = Process.monitor(client)
        {:ok, %{module: module, client: client, client_ref: ref, user_state: user_state}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:client_op, op, args}, _from, state) do
    {:reply, apply(MqttX.Client, op, [state.client | args]), state}
  end

  def handle_call({:disconnect, opts}, _from, state) do
    MqttX.Client.disconnect(state.client, opts)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:__mqttx_event__, :message, {topic, payload, packet}}, state) do
    dispatch(state, :handle_message, [topic, payload, packet])
  end

  def handle_info({:__mqttx_event__, :connected, info}, state) do
    dispatch(state, :handle_connected, [info])
  end

  def handle_info({:__mqttx_event__, :disconnected, reason}, state) do
    dispatch(state, :handle_disconnected, [reason])
  end

  def handle_info({:__mqttx_event__, :publish_error, {topic, packet_id, reason_code}}, state) do
    dispatch(state, :handle_publish_error, [topic, packet_id, reason_code])
  end

  def handle_info(
        {:DOWN, ref, :process, client, reason},
        %{client_ref: ref, client: client} = state
      ) do
    # The connection stopped for good (explicit disconnect or a fatal broker
    # rejection — transient failures reconnect internally without stopping).
    {:stop, reason, state}
  end

  def handle_info(message, state) do
    dispatch(state, :handle_info, [message])
  end

  defp dispatch(state, callback, args) do
    case apply(state.module, callback, args ++ [state.user_state]) do
      {:ok, user_state} -> {:noreply, %{state | user_state: user_state}}
      {:stop, reason, user_state} -> {:stop, reason, %{state | user_state: user_state}}
    end
  end
end
