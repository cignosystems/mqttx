defmodule MqttX.Client.Connection do
  @moduledoc """
  MQTT client connection GenServer.

  Manages a connection to an MQTT broker with automatic reconnection.

  ## Usage

      {:ok, pid} = MqttX.Client.Connection.start_link(
        host: "localhost",
        port: 1883,
        client_id: "my_client",
        handler: MyHandler,
        handler_state: %{}
      )

      :ok = MqttX.Client.Connection.subscribe(pid, "test/#", qos: 1)
      :ok = MqttX.Client.Connection.publish(pid, "test/topic", "hello", qos: 0)
  """

  use GenServer

  alias MqttX.Packet.Codec
  alias MqttX.Client.Backoff

  require Logger

  @default_port 1883
  @default_keepalive 60
  @connect_timeout 5000

  defstruct [
    :host,
    :port,
    :client_id,
    :username,
    :password,
    :socket,
    :handler,
    :handler_state,
    :keepalive,
    :keepalive_timer,
    :protocol_version,
    :backoff,
    :packet_id,
    :buffer,
    :pending_acks,
    connected: false,
    clean_session: true
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Start a client connection.

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
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Publish a message.

  ## Options

  - `:qos` - QoS level 0, 1, or 2 (default: 0)
  - `:retain` - Retain flag (default: false)
  """
  @spec publish(GenServer.server(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(pid, topic, payload, opts \\ []) do
    GenServer.call(pid, {:publish, topic, payload, opts})
  end

  @doc """
  Subscribe to topics.

  ## Options

  - `:qos` - QoS level 0, 1, or 2 (default: 0)
  """
  @spec subscribe(GenServer.server(), binary() | [binary()], keyword()) :: :ok | {:error, term()}
  def subscribe(pid, topics, opts \\ []) do
    topics = if is_binary(topics), do: [topics], else: topics
    GenServer.call(pid, {:subscribe, topics, opts})
  end

  @doc """
  Unsubscribe from topics.
  """
  @spec unsubscribe(GenServer.server(), binary() | [binary()]) :: :ok | {:error, term()}
  def unsubscribe(pid, topics) do
    topics = if is_binary(topics), do: [topics], else: topics
    GenServer.call(pid, {:unsubscribe, topics})
  end

  @doc """
  Disconnect from the broker.
  """
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(pid) do
    GenServer.cast(pid, :disconnect)
  end

  @doc """
  Check if connected.
  """
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(pid) do
    GenServer.call(pid, :connected?)
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, @default_port),
      client_id: Keyword.fetch!(opts, :client_id),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      clean_session: Keyword.get(opts, :clean_session, true),
      keepalive: Keyword.get(opts, :keepalive, @default_keepalive),
      handler: Keyword.get(opts, :handler),
      handler_state: Keyword.get(opts, :handler_state),
      protocol_version: Keyword.get(opts, :protocol_version, 4),
      backoff: Backoff.new(),
      packet_id: 1,
      buffer: <<>>,
      pending_acks: %{}
    }

    # Attempt initial connection
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call({:publish, topic, payload, opts}, _from, state) do
    if state.connected do
      qos = Keyword.get(opts, :qos, 0)
      retain = Keyword.get(opts, :retain, false)

      {packet_id, state} = if qos > 0, do: next_packet_id(state), else: {nil, state}

      packet = %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: qos,
        retain: retain,
        dup: false,
        packet_id: packet_id
      }

      case send_packet(state, packet) do
        :ok -> {:reply, :ok, state}
        {:error, _} = err -> {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:subscribe, topics, opts}, _from, state) do
    if state.connected do
      qos = Keyword.get(opts, :qos, 0)
      {packet_id, state} = next_packet_id(state)

      topic_list = Enum.map(topics, fn t -> %{topic: t, qos: qos} end)

      packet = %{
        type: :subscribe,
        packet_id: packet_id,
        topics: topic_list
      }

      case send_packet(state, packet) do
        :ok -> {:reply, :ok, state}
        {:error, _} = err -> {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:unsubscribe, topics}, _from, state) do
    if state.connected do
      {packet_id, state} = next_packet_id(state)

      packet = %{
        type: :unsubscribe,
        packet_id: packet_id,
        topics: topics
      }

      case send_packet(state, packet) do
        :ok -> {:reply, :ok, state}
        {:error, _} = err -> {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    send_packet(state, %{type: :disconnect})
    close_socket(state)
    {:stop, :normal, %{state | connected: false, socket: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, state} ->
        state = %{state | backoff: Backoff.reset(state.backoff)}
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[MqttX.Client] Connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info(:keepalive, state) do
    if state.connected do
      send_packet(state, %{type: :pingreq})
      timer = Process.send_after(self(), :keepalive, state.keepalive * 1000)
      {:noreply, %{state | keepalive_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = %{state | buffer: state.buffer <> data}
    state = process_buffer(state)
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("[MqttX.Client] Connection closed")
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    notify_handler(state, :disconnected, :closed)
    schedule_reconnect(state)
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("[MqttX.Client] TCP error: #{inspect(reason)}")
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    notify_handler(state, :disconnected, {:error, reason})
    schedule_reconnect(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # PRIVATE FUNCTIONS
  # ============================================================================

  defp do_connect(state) do
    host = to_charlist(state.host)

    case :gen_tcp.connect(host, state.port, [:binary, active: :once], @connect_timeout) do
      {:ok, socket} ->
        state = %{state | socket: socket}
        send_connect(state)

      {:error, _} = err ->
        err
    end
  end

  defp send_connect(state) do
    packet = %{
      type: :connect,
      protocol_version: state.protocol_version,
      client_id: state.client_id,
      clean_session: state.clean_session,
      keep_alive: state.keepalive,
      username: state.username,
      password: state.password
    }

    case send_packet(state, packet) do
      :ok -> wait_for_connack(state)
      {:error, _} = err -> err
    end
  end

  defp wait_for_connack(state) do
    receive do
      {:tcp, socket, data} when socket == state.socket ->
        case Codec.decode(state.protocol_version, data) do
          {:ok, {%{type: :connack, reason_code: 0}, rest}} ->
            Logger.info("[MqttX.Client] Connected to #{state.host}:#{state.port}")
            timer = Process.send_after(self(), :keepalive, state.keepalive * 1000)
            :inet.setopts(socket, active: :once)
            state = %{state | connected: true, buffer: rest, keepalive_timer: timer}
            notify_handler(state, :connected, nil)
            {:ok, state}

          {:ok, {%{type: :connack, reason_code: code}, _rest}} ->
            close_socket(state)
            {:error, {:connack_error, code}}

          {:error, :incomplete} ->
            # Need more data
            wait_for_connack(%{state | buffer: data})

          {:error, reason} ->
            close_socket(state)
            {:error, reason}
        end
    after
      @connect_timeout ->
        close_socket(state)
        {:error, :timeout}
    end
  end

  defp process_buffer(state) do
    case Codec.decode(state.protocol_version, state.buffer) do
      {:ok, {packet, rest}} ->
        state = handle_packet(packet, state)
        process_buffer(%{state | buffer: rest})

      {:error, :incomplete} ->
        state

      {:error, reason} ->
        Logger.warning("[MqttX.Client] Decode error: #{inspect(reason)}")
        state
    end
  end

  defp handle_packet(%{type: :publish} = packet, state) do
    notify_handler(state, :message, {packet.topic, packet.payload, packet})

    # Send PUBACK for QoS 1
    if packet.qos == 1 do
      send_packet(state, %{type: :puback, packet_id: packet.packet_id})
    end

    state
  end

  defp handle_packet(%{type: :puback} = packet, state) do
    # Remove from pending acks
    pending = Map.delete(state.pending_acks, packet.packet_id)
    %{state | pending_acks: pending}
  end

  defp handle_packet(%{type: :suback}, state) do
    state
  end

  defp handle_packet(%{type: :unsuback}, state) do
    state
  end

  defp handle_packet(%{type: :pingresp}, state) do
    state
  end

  defp handle_packet(_packet, state) do
    state
  end

  defp send_packet(state, packet) do
    case Codec.encode(state.protocol_version, packet) do
      {:ok, data} ->
        case :gen_tcp.send(state.socket, data) do
          :ok -> :ok
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp next_packet_id(state) do
    id = state.packet_id
    next_id = if id >= 65535, do: 1, else: id + 1
    {id, %{state | packet_id: next_id}}
  end

  defp schedule_reconnect(state) do
    {delay, backoff} = Backoff.next(state.backoff)
    Logger.info("[MqttX.Client] Reconnecting in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    %{state | backoff: backoff}
  end

  defp cancel_keepalive(state) do
    if state.keepalive_timer do
      Process.cancel_timer(state.keepalive_timer)
    end
  end

  defp close_socket(state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end
  end

  defp notify_handler(%{handler: nil}, _event, _data), do: :ok

  defp notify_handler(%{handler: handler, handler_state: hstate}, event, data) do
    if function_exported?(handler, :handle_mqtt_event, 3) do
      handler.handle_mqtt_event(event, data, hstate)
    end
  end
end
