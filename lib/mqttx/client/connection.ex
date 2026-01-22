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

  ## TLS/SSL Support

  To connect using TLS/SSL:

      {:ok, pid} = MqttX.Client.Connection.start_link(
        host: "broker.example.com",
        port: 8883,
        client_id: "my_client",
        transport: :ssl,
        ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
      )

  The `:transport` option defaults to `:tcp` for backward compatibility.
  """

  use GenServer

  alias MqttX.Packet.Codec
  alias MqttX.Client.Backoff
  alias MqttX.Telemetry

  require Logger

  @default_port 1883
  @default_ssl_port 8883
  @default_keepalive 60
  @default_retry_interval 5000
  @max_retries 3
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
    :ssl_opts,
    :retry_timer,
    :session_store,
    :session_store_state,
    :subscriptions,
    # Topic alias support (MQTT 5.0)
    :topic_alias_maximum,
    # Flow control (MQTT 5.0)
    :receive_maximum,
    transport: :tcp,
    retry_interval: @default_retry_interval,
    connected: false,
    clean_session: true,
    # Outgoing topic aliases (topic -> alias)
    topic_to_alias: %{},
    # Incoming topic aliases (alias -> topic)
    alias_to_topic: %{},
    next_alias: 1
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Start a client connection.

  ## Options

  - `:host` - Broker hostname (required)
  - `:port` - Broker port (default: 1883 for TCP, 8883 for SSL)
  - `:client_id` - Client identifier (required)
  - `:username` - Optional username
  - `:password` - Optional password
  - `:clean_session` - Clean session flag (default: true)
  - `:keepalive` - Keepalive interval in seconds (default: 60)
  - `:handler` - Module to receive callbacks
  - `:handler_state` - Initial state for handler
  - `:transport` - Transport type: `:tcp` or `:ssl` (default: `:tcp`)
  - `:ssl_opts` - SSL options when transport is `:ssl` (e.g., `[verify: :verify_peer]`)
  - `:retry_interval` - Retry interval for unacknowledged QoS 1/2 messages in ms (default: 5000)
  - `:session_store` - Session store module or `{module, opts}` for session persistence
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
    transport = Keyword.get(opts, :transport, :tcp)
    default_port = if transport == :ssl, do: @default_ssl_port, else: @default_port
    client_id = Keyword.fetch!(opts, :client_id)
    clean_session = Keyword.get(opts, :clean_session, true)

    # Initialize session store if configured
    {session_store, session_store_state} = init_session_store(Keyword.get(opts, :session_store))

    # Load existing session if not clean_session
    {packet_id, pending_acks, subscriptions} =
      if not clean_session and session_store do
        load_session(client_id, session_store, session_store_state)
      else
        {1, %{}, []}
      end

    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, default_port),
      client_id: client_id,
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      clean_session: clean_session,
      keepalive: Keyword.get(opts, :keepalive, @default_keepalive),
      handler: Keyword.get(opts, :handler),
      handler_state: Keyword.get(opts, :handler_state),
      protocol_version: Keyword.get(opts, :protocol_version, 4),
      transport: transport,
      ssl_opts: Keyword.get(opts, :ssl_opts, []),
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval),
      session_store: session_store,
      session_store_state: session_store_state,
      subscriptions: subscriptions,
      backoff: Backoff.new(),
      packet_id: packet_id,
      buffer: <<>>,
      pending_acks: pending_acks
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
      properties = Keyword.get(opts, :properties, %{})

      # Check flow control for QoS 1/2 (MQTT 5.0 receive_maximum)
      if qos > 0 and not can_send_qos_message?(state) do
        {:reply, {:error, :flow_control}, state}
      else
        {packet_id, state} = if qos > 0, do: next_packet_id(state), else: {nil, state}

        packet = %{
          type: :publish,
          topic: topic,
          payload: payload,
          qos: qos,
          retain: retain,
          dup: false,
          packet_id: packet_id,
          properties: properties
        }

        # Emit telemetry for publish
        telemetry_meta = %{
          client_id: state.client_id,
          topic: topic,
          qos: qos,
          payload_size: byte_size(payload)
        }

        Telemetry.client_publish_start(telemetry_meta)

        case send_packet(state, packet) do
          :ok ->
            # For QoS 0, publish is complete immediately
            if qos == 0 do
              Telemetry.client_publish_stop(0, telemetry_meta)
            end

            # Track pending acks for QoS 1 and 2
            state =
              case qos do
                0 ->
                  state

                1 ->
                  # QoS 1: waiting for PUBACK
                  pending =
                    Map.put(state.pending_acks, {:tx, packet_id}, %{
                      phase: :puback_pending,
                      packet: packet,
                      timestamp: System.monotonic_time(:millisecond),
                      telemetry_meta: telemetry_meta
                    })

                  %{state | pending_acks: pending}

                2 ->
                  # QoS 2: waiting for PUBREC
                  pending =
                    Map.put(state.pending_acks, {:tx, packet_id}, %{
                      phase: :pubrec_pending,
                      packet: packet,
                      timestamp: System.monotonic_time(:millisecond),
                      telemetry_meta: telemetry_meta
                    })

                  %{state | pending_acks: pending}
              end

            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
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

      # Emit telemetry for subscribe
      Telemetry.client_subscribe(%{client_id: state.client_id, topics: topics})

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
    Telemetry.client_disconnect(%{client_id: state.client_id, reason: :normal})
    send_packet(state, %{type: :disconnect})
    close_socket(state)
    # Save session before stopping
    save_session(state)
    {:stop, :normal, %{state | connected: false, socket: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    metadata = %{
      host: state.host,
      port: state.port,
      client_id: state.client_id,
      transport: state.transport
    }

    start_time = System.monotonic_time()
    Telemetry.client_connect_start(metadata)

    case do_connect(state) do
      {:ok, state} ->
        duration = System.monotonic_time() - start_time
        Telemetry.client_connect_stop(duration, metadata)
        state = %{state | backoff: Backoff.reset(state.backoff)}
        {:noreply, state}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time
        Telemetry.client_connect_exception(duration, Map.put(metadata, :reason, reason))
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

  def handle_info(:check_inflight, state) do
    if state.connected do
      state = retry_expired_messages(state)
      timer = Process.send_after(self(), :check_inflight, state.retry_interval)
      {:noreply, %{state | retry_timer: timer}}
    else
      {:noreply, state}
    end
  end

  # Handle incoming data from both TCP and SSL sockets
  def handle_info({proto, socket, data}, %{socket: socket} = state)
      when proto in [:tcp, :ssl] do
    state = %{state | buffer: state.buffer <> data}
    state = process_buffer(state)
    set_socket_active(state)
    {:noreply, state}
  end

  # Handle socket closed for both TCP and SSL
  def handle_info({closed, socket}, %{socket: socket} = state)
      when closed in [:tcp_closed, :ssl_closed] do
    Logger.info("[MqttX.Client] Connection closed")
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    cancel_retry_timer(state)
    notify_handler(state, :disconnected, :closed)
    schedule_reconnect(state)
    {:noreply, state}
  end

  # Handle socket errors for both TCP and SSL
  def handle_info({error, socket, reason}, %{socket: socket} = state)
      when error in [:tcp_error, :ssl_error] do
    Logger.warning("[MqttX.Client] Socket error: #{inspect(reason)}")
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    cancel_retry_timer(state)
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

  defp do_connect(%{transport: :tcp} = state) do
    host = to_charlist(state.host)

    case :gen_tcp.connect(host, state.port, [:binary, active: :once], @connect_timeout) do
      {:ok, socket} ->
        state = %{state | socket: socket}
        send_connect(state)

      {:error, _} = err ->
        err
    end
  end

  defp do_connect(%{transport: :ssl} = state) do
    host = to_charlist(state.host)
    ssl_opts = [:binary, {:active, :once}] ++ (state.ssl_opts || [])

    case :ssl.connect(host, state.port, ssl_opts, @connect_timeout) do
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
      {proto, socket, data} when proto in [:tcp, :ssl] and socket == state.socket ->
        case Codec.decode(state.protocol_version, data) do
          {:ok, {%{type: :connack, reason_code: 0} = connack, rest}} ->
            Logger.info("[MqttX.Client] Connected to #{state.host}:#{state.port}")
            keepalive_timer = Process.send_after(self(), :keepalive, state.keepalive * 1000)
            retry_timer = Process.send_after(self(), :check_inflight, state.retry_interval)
            set_socket_active(state)

            # Extract MQTT 5.0 properties from CONNACK
            props = Map.get(connack, :properties, %{})
            topic_alias_max = Map.get(props, :topic_alias_maximum)
            receive_max = Map.get(props, :receive_maximum, 65535)

            state = %{
              state
              | connected: true,
                buffer: rest,
                keepalive_timer: keepalive_timer,
                retry_timer: retry_timer,
                topic_alias_maximum: topic_alias_max,
                receive_maximum: receive_max
            }

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
    # Handle topic alias (MQTT 5.0)
    {topic, state} = resolve_incoming_topic_alias(packet, state)
    packet = %{packet | topic: topic}

    # Emit telemetry for received message (for QoS 0 and 1, immediately; QoS 2 after PUBREL)
    emit_message_telemetry = fn ->
      payload_size = byte_size(packet.payload || <<>>)

      Telemetry.client_message(payload_size, %{
        client_id: state.client_id,
        topic: topic,
        qos: packet.qos
      })
    end

    case packet.qos do
      0 ->
        # QoS 0: deliver immediately, no acknowledgment
        emit_message_telemetry.()
        notify_handler(state, :message, {topic, packet.payload, packet})
        state

      1 ->
        # QoS 1: deliver and send PUBACK
        emit_message_telemetry.()
        notify_handler(state, :message, {topic, packet.payload, packet})
        send_packet(state, %{type: :puback, packet_id: packet.packet_id})
        state

      2 ->
        # QoS 2: store message, send PUBREC, wait for PUBREL before delivering
        # Telemetry will be emitted when PUBREL is received
        # Store in pending_acks with :pubrec_sent phase
        pending =
          Map.put(state.pending_acks, {:rx, packet.packet_id}, %{
            phase: :pubrec_sent,
            packet: packet
          })

        send_packet(state, %{type: :pubrec, packet_id: packet.packet_id})
        %{state | pending_acks: pending}
    end
  end

  defp handle_packet(%{type: :puback} = packet, state) do
    # QoS 1 complete: emit telemetry and remove from pending acks
    case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
      %{timestamp: ts, telemetry_meta: meta} ->
        duration = System.monotonic_time(:millisecond) - ts
        Telemetry.client_publish_stop(duration, meta)

      _ ->
        :ok
    end

    pending = Map.delete(state.pending_acks, {:tx, packet.packet_id})
    %{state | pending_acks: pending}
  end

  # QoS 2 - received PUBREC for our outgoing PUBLISH
  defp handle_packet(%{type: :pubrec} = packet, state) do
    case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
      %{phase: :pubrec_pending} = entry ->
        # Send PUBREL and wait for PUBCOMP
        send_packet(state, %{type: :pubrel, packet_id: packet.packet_id})

        pending =
          Map.put(state.pending_acks, {:tx, packet.packet_id}, %{entry | phase: :pubcomp_pending})

        %{state | pending_acks: pending}

      _ ->
        # Unexpected PUBREC, ignore
        state
    end
  end

  # QoS 2 - received PUBREL for incoming PUBLISH (server finished receiving our PUBREC)
  defp handle_packet(%{type: :pubrel} = packet, state) do
    case Map.get(state.pending_acks, {:rx, packet.packet_id}) do
      %{phase: :pubrec_sent, packet: publish_packet} ->
        # Emit telemetry for QoS 2 received message
        payload_size = byte_size(publish_packet.payload || <<>>)

        Telemetry.client_message(payload_size, %{
          client_id: state.client_id,
          topic: publish_packet.topic,
          qos: publish_packet.qos
        })

        # Now deliver the message to handler and send PUBCOMP
        notify_handler(
          state,
          :message,
          {publish_packet.topic, publish_packet.payload, publish_packet}
        )

        send_packet(state, %{type: :pubcomp, packet_id: packet.packet_id})
        pending = Map.delete(state.pending_acks, {:rx, packet.packet_id})
        %{state | pending_acks: pending}

      _ ->
        # Unexpected PUBREL, ignore
        state
    end
  end

  # QoS 2 - received PUBCOMP for our outgoing PUBLISH (transaction complete)
  defp handle_packet(%{type: :pubcomp} = packet, state) do
    # QoS 2 complete: emit telemetry
    case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
      %{timestamp: ts, telemetry_meta: meta} ->
        duration = System.monotonic_time(:millisecond) - ts
        Telemetry.client_publish_stop(duration, meta)

      _ ->
        :ok
    end

    pending = Map.delete(state.pending_acks, {:tx, packet.packet_id})
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
        socket_send(state, data)

      {:error, _} = err ->
        err
    end
  end

  defp socket_send(%{transport: :tcp, socket: socket}, data) do
    :gen_tcp.send(socket, data)
  end

  defp socket_send(%{transport: :ssl, socket: socket}, data) do
    :ssl.send(socket, data)
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

  defp cancel_retry_timer(state) do
    if state.retry_timer do
      Process.cancel_timer(state.retry_timer)
    end
  end

  defp retry_expired_messages(state) do
    now = System.monotonic_time(:millisecond)

    {to_retry, _to_remove, pending} =
      Enum.reduce(state.pending_acks, {[], [], state.pending_acks}, fn
        {{:tx, packet_id} = key, %{packet: packet, timestamp: ts, retries: retries} = entry},
        {retry, remove, acc} ->
          age = now - ts

          cond do
            # Message expired and exceeded max retries - remove it
            age > state.retry_interval and retries >= @max_retries ->
              Logger.warning(
                "[MqttX.Client] Dropping packet #{packet_id} after #{retries} retries"
              )

              {retry, [key | remove], Map.delete(acc, key)}

            # Message expired - retry it
            age > state.retry_interval ->
              updated_entry = %{entry | timestamp: now, retries: retries + 1}

              {[{packet_id, packet, entry.phase} | retry], remove,
               Map.put(acc, key, updated_entry)}

            # Message not expired yet
            true ->
              {retry, remove, acc}
          end

        # Skip received messages (rx) - they don't need retry
        _other, acc ->
          acc
      end)

    # Resend expired messages with dup flag
    Enum.each(to_retry, fn {packet_id, packet, phase} ->
      resend_packet(state, packet_id, packet, phase)
    end)

    %{state | pending_acks: pending}
  end

  defp resend_packet(state, packet_id, packet, phase) do
    case phase do
      :puback_pending ->
        # QoS 1: resend PUBLISH with dup=true
        Logger.debug("[MqttX.Client] Retrying PUBLISH packet #{packet_id}")
        send_packet(state, %{packet | dup: true})

      :pubrec_pending ->
        # QoS 2 phase 1: resend PUBLISH with dup=true
        Logger.debug("[MqttX.Client] Retrying PUBLISH packet #{packet_id}")
        send_packet(state, %{packet | dup: true})

      :pubcomp_pending ->
        # QoS 2 phase 2: resend PUBREL
        Logger.debug("[MqttX.Client] Retrying PUBREL packet #{packet_id}")
        send_packet(state, %{type: :pubrel, packet_id: packet_id})

      _ ->
        :ok
    end
  end

  defp close_socket(%{socket: nil}), do: :ok

  defp close_socket(%{transport: :tcp, socket: socket}) do
    :gen_tcp.close(socket)
  end

  defp close_socket(%{transport: :ssl, socket: socket}) do
    :ssl.close(socket)
  end

  defp set_socket_active(%{transport: :tcp, socket: socket}) do
    :inet.setopts(socket, active: :once)
  end

  defp set_socket_active(%{transport: :ssl, socket: socket}) do
    :ssl.setopts(socket, active: :once)
  end

  defp notify_handler(%{handler: nil}, _event, _data), do: :ok

  defp notify_handler(%{handler: handler, handler_state: hstate}, event, data) do
    if function_exported?(handler, :handle_mqtt_event, 3) do
      handler.handle_mqtt_event(event, data, hstate)
    end
  end

  # Session store helpers
  defp init_session_store(nil), do: {nil, nil}

  defp init_session_store({module, opts}) when is_atom(module) do
    case module.init(opts) do
      {:ok, state} -> {module, state}
      {:error, _} -> {nil, nil}
    end
  end

  defp init_session_store(module) when is_atom(module) do
    init_session_store({module, []})
  end

  defp load_session(client_id, store, store_state) do
    case store.load(client_id, store_state) do
      {:ok, session} ->
        packet_id = Map.get(session, :packet_id, 1)
        pending_acks = Map.get(session, :pending_acks, %{})
        subscriptions = Map.get(session, :subscriptions, [])
        {packet_id, pending_acks, subscriptions}

      :not_found ->
        {1, %{}, []}

      {:error, _} ->
        {1, %{}, []}
    end
  end

  defp save_session(state) do
    if state.session_store and not state.clean_session do
      session = %{
        packet_id: state.packet_id,
        pending_acks: state.pending_acks,
        subscriptions: state.subscriptions
      }

      state.session_store.save(state.client_id, session, state.session_store_state)
    end
  end

  # ============================================================================
  # Flow Control Helpers (MQTT 5.0)
  # ============================================================================

  # Check if we can send another QoS 1/2 message (respects receive_maximum)
  defp can_send_qos_message?(state) do
    max_inflight = state.receive_maximum || 65535
    inflight_count = count_inflight_messages(state)
    inflight_count < max_inflight
  end

  # Count outgoing messages waiting for acknowledgment
  defp count_inflight_messages(state) do
    state.pending_acks
    |> Enum.count(fn
      {{:tx, _}, _} -> true
      _ -> false
    end)
  end

  # ============================================================================
  # Topic Alias Helpers (MQTT 5.0)
  # ============================================================================

  # Resolve topic alias for incoming PUBLISH messages
  defp resolve_incoming_topic_alias(packet, state) do
    topic_alias = get_in(packet, [:properties, :topic_alias])
    topic = packet.topic

    cond do
      # No alias in packet
      is_nil(topic_alias) ->
        {topic, state}

      # Alias with topic: store the mapping
      is_binary(topic) and topic != "" ->
        alias_to_topic = Map.put(state.alias_to_topic, topic_alias, topic)
        {topic, %{state | alias_to_topic: alias_to_topic}}

      # Alias only: look up from stored mapping
      true ->
        resolved_topic = Map.get(state.alias_to_topic, topic_alias, "")
        {resolved_topic, state}
    end
  end
end
