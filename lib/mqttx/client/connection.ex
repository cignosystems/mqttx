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
  @default_ws_port 8083
  @default_wss_port 8084
  @default_keepalive 60
  @default_retry_interval 5000
  @default_max_inflight 100
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
    # Local cap on pending QoS 1/2 messages (prevents unbounded memory growth)
    :max_inflight,
    # Maximum outgoing packet size (MQTT 5.0, from CONNACK)
    :server_maximum_packet_size,
    # Will message (Last Will & Testament)
    :will,
    # CONNECT properties (MQTT 5.0: session_expiry_interval, topic_alias_maximum, etc.)
    connect_properties: %{},
    transport: :tcp,
    retry_interval: @default_retry_interval,
    connected: false,
    clean_session: true,
    # Incoming topic aliases (alias -> topic, MQTT 5.0)
    alias_to_topic: %{},
    # Outgoing topic aliases (topic -> alias, MQTT 5.0)
    topic_to_alias: %{},
    next_alias: 1,
    # Server's topic_alias_maximum (from CONNACK, for outgoing aliases)
    server_topic_alias_maximum: 0,
    # WebSocket path (for :ws/:wss transport)
    ws_path: "/mqtt",
    # WebSocket frame buffer (for :ws/:wss transport)
    ws_buffer: <<>>,
    # WebSocket fragmentation state — partial multi-frame message in flight
    ws_frag: {<<>>, nil},
    # Pending callers waiting for SUBACK/UNSUBACK
    pending_subs: %{},
    handler_has_handle_mqtt_event: false,
    inflight_tx_count: 0,
    # Outstanding PINGREQ deadline timer (close connection if no PINGRESP arrives)
    pingresp_timer: nil,
    # Pending reconnect timer (avoid stacking timers when several events fire)
    reconnect_timer: nil
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
  - `:transport` - Transport type: `:tcp`, `:ssl`, `:ws`, or `:wss` (default: `:tcp`)
  - `:ssl_opts` - SSL options when transport is `:ssl` or `:wss` (e.g., `[verify: :verify_peer]`)
  - `:ws_path` - WebSocket path when transport is `:ws` or `:wss` (default: "/mqtt")
  - `:retry_interval` - Retry interval for unacknowledged QoS 1/2 messages in ms (default: 5000)
  - `:max_inflight` - Maximum pending QoS 1/2 messages before backpressure (default: 100)
  - `:will_topic` - Will message topic (enables Last Will & Testament)
  - `:will_payload` - Will message payload (default: `""`)
  - `:will_qos` - Will message QoS: 0, 1, or 2 (default: 0)
  - `:will_retain` - Will message retain flag (default: false)
  - `:will_properties` - Will message properties map (MQTT 5.0, default: `%{}`)
  - `:connect_properties` - CONNECT packet properties (MQTT 5.0), e.g. `%{session_expiry_interval: 3600}`
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
  - `:no_local` - Don't receive own publishes (MQTT 5.0, default: false)
  - `:retain_as_published` - Keep original retain flag (MQTT 5.0, default: false)
  - `:retain_handling` - Retained message behavior: 0=send on subscribe, 1=send if new, 2=don't send (MQTT 5.0, default: 0)
  - `:properties` - SUBSCRIBE packet properties map (MQTT 5.0), e.g. `%{subscription_identifier: 1}`
  """
  @spec subscribe(GenServer.server(), binary() | [binary()], keyword()) ::
          {:ok, [integer()]} | {:error, term()}
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

  ## Options (MQTT 5.0)

  - `:reason_code` - Disconnect reason code (default: 0x00 Normal)
  - `:properties` - Disconnect properties map, e.g. `%{session_expiry_interval: 0}`
  """
  @spec disconnect(GenServer.server(), keyword()) :: :ok
  def disconnect(pid, opts \\ []) do
    GenServer.cast(pid, {:disconnect, opts})
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

    default_port =
      case transport do
        :ssl -> @default_ssl_port
        :ws -> @default_ws_port
        :wss -> @default_wss_port
        _ -> @default_port
      end

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

    handler = Keyword.get(opts, :handler)

    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, default_port),
      client_id: client_id,
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      clean_session: clean_session,
      keepalive: Keyword.get(opts, :keepalive, @default_keepalive),
      handler: handler,
      handler_state: Keyword.get(opts, :handler_state),
      protocol_version: Keyword.get(opts, :protocol_version, 5),
      transport: transport,
      ssl_opts: Keyword.get(opts, :ssl_opts, []),
      ws_path: Keyword.get(opts, :ws_path, "/mqtt"),
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval),
      session_store: session_store,
      session_store_state: session_store_state,
      subscriptions: subscriptions,
      backoff: Backoff.new(),
      packet_id: packet_id,
      buffer: <<>>,
      pending_acks: pending_acks,
      max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
      will: build_will(opts),
      connect_properties: Keyword.get(opts, :connect_properties, %{}),
      handler_has_handle_mqtt_event:
        if(handler, do: function_exported?(handler, :handle_mqtt_event, 3), else: false)
    }

    # Register with ClientRegistry for lookup by client_id
    Registry.register(MqttX.ClientRegistry, client_id, %{host: state.host, port: state.port})

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

        # Apply outgoing topic alias (MQTT 5.0)
        {publish_topic, publish_properties, state} =
          apply_outgoing_topic_alias(topic, properties, state)

        packet = %{
          type: :publish,
          topic: publish_topic,
          payload: payload,
          qos: qos,
          retain: retain,
          dup: false,
          packet_id: packet_id,
          properties: publish_properties
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
                      telemetry_meta: telemetry_meta,
                      retries: 0
                    })

                  %{state | pending_acks: pending, inflight_tx_count: state.inflight_tx_count + 1}

                2 ->
                  # QoS 2: waiting for PUBREC
                  pending =
                    Map.put(state.pending_acks, {:tx, packet_id}, %{
                      phase: :pubrec_pending,
                      packet: packet,
                      timestamp: System.monotonic_time(:millisecond),
                      telemetry_meta: telemetry_meta,
                      retries: 0
                    })

                  %{state | pending_acks: pending, inflight_tx_count: state.inflight_tx_count + 1}
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

  def handle_call({:subscribe, topics, opts}, from, state) do
    if state.connected do
      qos = Keyword.get(opts, :qos, 0)
      no_local = Keyword.get(opts, :no_local, false)
      retain_as_published = Keyword.get(opts, :retain_as_published, false)
      retain_handling = Keyword.get(opts, :retain_handling, 0)
      {packet_id, state} = next_packet_id(state)

      topic_list =
        Enum.map(topics, fn t ->
          %{
            topic: t,
            qos: qos,
            no_local: no_local,
            retain_as_published: retain_as_published,
            retain_handling: retain_handling
          }
        end)

      subscribe_props = Keyword.get(opts, :properties, %{})

      packet = %{
        type: :subscribe,
        packet_id: packet_id,
        topics: topic_list,
        properties: subscribe_props
      }

      # Emit telemetry for subscribe
      Telemetry.client_subscribe(%{client_id: state.client_id, topics: topics})

      case send_packet(state, packet) do
        :ok ->
          # Wait for SUBACK asynchronously. Monitor the caller so we drop the
          # pending entry if they crash or `GenServer.call/3` times out and the
          # caller is no longer interested in the reply.
          {caller_pid, _} = from
          monitor = Process.monitor(caller_pid)
          pending = Map.put(state.pending_subs, packet_id, {:subscribe, from, monitor})
          {:noreply, %{state | pending_subs: pending}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:unsubscribe, topics}, from, state) do
    if state.connected do
      {packet_id, state} = next_packet_id(state)

      packet = %{
        type: :unsubscribe,
        packet_id: packet_id,
        topics: topics
      }

      case send_packet(state, packet) do
        :ok ->
          {caller_pid, _} = from
          monitor = Process.monitor(caller_pid)
          pending = Map.put(state.pending_subs, packet_id, {:unsubscribe, from, monitor})
          {:noreply, %{state | pending_subs: pending}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_cast({:disconnect, opts}, state) do
    reason_code = Keyword.get(opts, :reason_code, 0)
    properties = Keyword.get(opts, :properties, %{})

    Telemetry.client_disconnect(%{client_id: state.client_id, reason: :normal})

    send_packet(state, %{
      type: :disconnect,
      reason_code: reason_code,
      properties: properties
    })

    close_socket(state)
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

        # Process any data that arrived after CONNACK (e.g. queued messages for persistent sessions)
        state = if state.buffer != <<>>, do: process_buffer(state), else: state
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
    cond do
      not state.connected ->
        {:noreply, state}

      state.keepalive == 0 ->
        # §3.1.2.10: Keep Alive 0 disables the mechanism entirely.
        {:noreply, state}

      true ->
        send_packet(state, %{type: :pingreq})
        timer = Process.send_after(self(), :keepalive, state.keepalive * 1000)
        # Arm a deadline: if PINGRESP doesn't arrive within keepalive*1500 ms
        # (1.5×, mirroring the server-side rule), tear the socket down.
        pingresp_timer = arm_pingresp_timer(state)

        {:noreply, %{state | keepalive_timer: timer, pingresp_timer: pingresp_timer}}
    end
  end

  def handle_info(:pingresp_timeout, state) do
    Logger.warning("[MqttX.Client] PINGRESP timeout — closing socket")
    close_socket(state)
    state = %{state | connected: false, socket: nil, pingresp_timer: nil}
    cancel_keepalive(state)
    cancel_retry_timer(state)
    state = notify_handler(state, :disconnected, :pingresp_timeout)
    state = schedule_reconnect(state)
    {:noreply, state}
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
    state =
      if state.transport in [:ws, :wss] do
        handle_ws_data(data, state)
      else
        buffer =
          case state.buffer do
            <<>> -> data
            buf -> buf <> data
          end

        %{state | buffer: buffer}
      end

    state = process_buffer(state)
    set_socket_active(state)
    {:noreply, state}
  end

  # Handle socket closed for TCP, SSL, WS, WSS
  def handle_info({closed, socket}, %{socket: socket} = state)
      when closed in [:tcp_closed, :ssl_closed] do
    Logger.info("[MqttX.Client] Connection closed")
    save_session(state)
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    cancel_retry_timer(state)
    state = notify_handler(state, :disconnected, :closed)
    schedule_reconnect(state)
    {:noreply, state}
  end

  # Handle socket errors for both TCP and SSL
  def handle_info({error, socket, reason}, %{socket: socket} = state)
      when error in [:tcp_error, :ssl_error] do
    Logger.warning("[MqttX.Client] Socket error: #{inspect(reason)}")
    save_session(state)
    state = %{state | connected: false, socket: nil}
    cancel_keepalive(state)
    cancel_retry_timer(state)
    state = notify_handler(state, :disconnected, {:error, reason})
    schedule_reconnect(state)
    {:noreply, state}
  end

  # Caller of subscribe/unsubscribe died (e.g. GenServer.call timed out and
  # caller exited). Drop the matching pending_subs entry so we don't leak.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    pending =
      state.pending_subs
      |> Enum.reject(fn
        {_pid, {_kind, _from, ^monitor}} -> true
        _ -> false
      end)
      |> Map.new()

    {:noreply, %{state | pending_subs: pending}}
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

  defp do_connect(%{transport: :ws} = state) do
    host = to_charlist(state.host)

    case :gen_tcp.connect(host, state.port, [:binary, active: false], @connect_timeout) do
      {:ok, socket} ->
        case MqttX.Client.WebSocket.upgrade(socket, :tcp, state.host, state.ws_path) do
          :ok ->
            :inet.setopts(socket, active: :once)
            state = %{state | socket: socket, ws_buffer: <<>>}
            send_connect(state)

          {:error, _} = err ->
            :gen_tcp.close(socket)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_connect(%{transport: :wss} = state) do
    host = to_charlist(state.host)
    ssl_opts = [:binary, {:active, false}] ++ (state.ssl_opts || [])

    case :ssl.connect(host, state.port, ssl_opts, @connect_timeout) do
      {:ok, socket} ->
        case MqttX.Client.WebSocket.upgrade(socket, :ssl, state.host, state.ws_path) do
          :ok ->
            :ssl.setopts(socket, active: :once)
            state = %{state | socket: socket, ws_buffer: <<>>}
            send_connect(state)

          {:error, _} = err ->
            :ssl.close(socket)
            err
        end

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
      password: state.password,
      will: state.will,
      properties: state.connect_properties
    }

    case send_packet(state, packet) do
      :ok -> wait_for_connack(state)
      {:error, _} = err -> err
    end
  end

  defp wait_for_connack(state) do
    receive do
      {proto, socket, data} when proto in [:tcp, :ssl] and socket == state.socket ->
        # Unwrap WebSocket frames if ws/wss transport. Fragment state isn't
        # threaded here (this path runs only inside the synchronous CONNECT
        # handshake, where servers don't fragment); production frames go via
        # handle_ws_data/2 which preserves the frag state across reads.
        data =
          if state.transport in [:ws, :wss] do
            case MqttX.Client.WebSocket.decode_frames(data) do
              {:ok, payloads, _rest, _frag} -> IO.iodata_to_binary(payloads)
              {:close, payloads} -> IO.iodata_to_binary(payloads)
            end
          else
            data
          end

        case Codec.decode(state.protocol_version, data) do
          {:ok, {%{type: :connack, reason_code: 0} = connack, rest}} ->
            Logger.info("[MqttX.Client] Connected to #{state.host}:#{state.port}")

            # Extract MQTT 5.0 properties from CONNACK
            props = Map.get(connack, :properties, %{})
            topic_alias_max = Map.get(props, :topic_alias_maximum)
            receive_max = Map.get(props, :receive_maximum, 65535)
            max_packet_size = Map.get(props, :maximum_packet_size)
            session_present = Map.get(connack, :session_present, false)

            # MQTT-3.2.2-2: server MUST NOT report session_present=true if we
            # asked for clean_start. Surface a warning; the handler can decide
            # whether to abort.
            if state.clean_session and session_present do
              Logger.warning(
                "[MqttX.Client] Broker returned session_present=true despite clean_session=true (MQTT-3.2.2-2)"
              )
            end

            # Server may override keepalive (MQTT 5.0 §3.2.2.3.14)
            keepalive =
              case Map.get(props, :server_keep_alive) do
                nil -> state.keepalive
                val -> val
              end

            # Server may assign a client identifier (MQTT 5.0 §3.2.2.3.7)
            client_id =
              case Map.get(props, :assigned_client_identifier) do
                nil -> state.client_id
                val -> val
              end

            keepalive_timer =
              if keepalive > 0,
                do: Process.send_after(self(), :keepalive, keepalive * 1000),
                else: nil

            retry_timer = Process.send_after(self(), :check_inflight, state.retry_interval)
            set_socket_active(state)

            # Server's topic_alias_maximum tells us how many outgoing aliases we can use
            server_tam = Map.get(props, :topic_alias_maximum, 0)

            state = %{
              state
              | connected: true,
                buffer: rest,
                keepalive_timer: keepalive_timer,
                retry_timer: retry_timer,
                keepalive: keepalive,
                client_id: client_id,
                topic_alias_maximum: topic_alias_max,
                receive_maximum: receive_max,
                server_maximum_packet_size: max_packet_size,
                server_topic_alias_maximum: server_tam,
                topic_to_alias: %{},
                next_alias: 1
            }

            state =
              notify_handler(state, :connected, %{
                properties: props,
                session_present: session_present
              })

            {:ok, state}

          {:ok, {%{type: :connack, reason_code: code} = connack, _rest}} ->
            props = Map.get(connack, :properties, %{})
            server_ref = Map.get(props, :server_reference)
            log_reason_string(props)

            if server_ref do
              Logger.info("[MqttX.Client] Server reference: #{server_ref}")
            end

            close_socket(state)
            {:error, {:connack_error, code, %{server_reference: server_ref}}}

          # Enhanced AUTH continuation during connect (MQTT 5.0 §4.12)
          {:ok, {%{type: :auth, reason_code: 0x18} = auth_packet, rest}} ->
            props = Map.get(auth_packet, :properties, %{})

            case notify_handler_auth(state, 0x18, props) do
              {:continue, auth_data, state} ->
                send_packet(state, %{
                  type: :auth,
                  reason_code: 0x18,
                  properties: %{
                    authentication_method: Map.get(props, :authentication_method),
                    authentication_data: auth_data
                  }
                })

                # Re-arm `active: :once` so the next AUTH/CONNACK packet is delivered
                # to the mailbox; otherwise wait_for_connack hangs until @connect_timeout.
                set_socket_active(state)
                wait_for_connack(%{state | buffer: rest})

              {:ok, state} ->
                set_socket_active(state)
                wait_for_connack(%{state | buffer: rest})
            end

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
        state = notify_handler(state, :message, {topic, packet.payload, packet})
        state

      1 ->
        # QoS 1: deliver and send PUBACK
        emit_message_telemetry.()
        state = notify_handler(state, :message, {topic, packet.payload, packet})
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
    log_reason_string(Map.get(packet, :properties, %{}))

    # QoS 1 complete: emit telemetry and remove from pending acks
    case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
      %{timestamp: ts, telemetry_meta: meta} ->
        duration = System.monotonic_time(:millisecond) - ts
        Telemetry.client_publish_stop(duration, meta)

      _ ->
        :ok
    end

    pending = Map.delete(state.pending_acks, {:tx, packet.packet_id})
    %{state | pending_acks: pending, inflight_tx_count: max(0, state.inflight_tx_count - 1)}
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
        state =
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
    %{state | pending_acks: pending, inflight_tx_count: max(0, state.inflight_tx_count - 1)}
  end

  defp handle_packet(%{type: :suback} = packet, state) do
    packet_id = packet.packet_id
    acks = Map.get(packet, :acks, [])
    props = Map.get(packet, :properties, %{})
    log_reason_string(props)

    case Map.pop(state.pending_subs, packet_id) do
      {{:subscribe, from, monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        # Check if any subscription was rejected
        reply =
          if Enum.all?(acks, &match?({:ok, _}, &1)) do
            {:ok, Enum.map(acks, fn {:ok, qos} -> qos end)}
          else
            {:error, {:subscription_refused, acks}}
          end

        GenServer.reply(from, reply)
        %{state | pending_subs: pending}

      {nil, _} ->
        state
    end
  end

  defp handle_packet(%{type: :unsuback} = packet, state) do
    packet_id = packet.packet_id
    props = Map.get(packet, :properties, %{})
    log_reason_string(props)

    case Map.pop(state.pending_subs, packet_id) do
      {{:unsubscribe, from, monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, :ok)
        %{state | pending_subs: pending}

      {nil, _} ->
        state
    end
  end

  defp handle_packet(%{type: :pingresp}, state) do
    cancel_pingresp_timer(state)
  end

  # Enhanced authentication (MQTT 5.0 §4.12)
  defp handle_packet(%{type: :auth} = packet, state) do
    reason_code = Map.get(packet, :reason_code, 0)
    props = Map.get(packet, :properties, %{})

    case notify_handler_auth(state, reason_code, props) do
      {:continue, auth_data, state} ->
        send_packet(state, %{
          type: :auth,
          reason_code: 0x18,
          properties: %{
            authentication_method: Map.get(props, :authentication_method),
            authentication_data: auth_data
          }
        })

        state

      {:ok, state} ->
        state
    end
  end

  defp handle_packet(%{type: :disconnect} = packet, state) do
    reason_code = Map.get(packet, :reason_code, 0)
    props = Map.get(packet, :properties, %{})
    server_ref = Map.get(props, :server_reference)
    log_reason_string(props)

    if server_ref do
      Logger.info("[MqttX.Client] Server reference on disconnect: #{server_ref}")
    end

    state =
      notify_handler(
        state,
        :disconnected,
        {:server_disconnect, reason_code, %{server_reference: server_ref}}
      )

    # §4.13: server-initiated DISCONNECT — tear the socket down and reconnect
    # rather than wait for {:tcp_closed, _} to land separately.
    close_socket(state)
    cancel_keepalive(state)
    cancel_retry_timer(state)
    state = %{state | connected: false, socket: nil}
    schedule_reconnect(state)
  end

  defp handle_packet(_packet, state) do
    state
  end

  defp send_packet(state, packet) do
    case Codec.encode_iodata(state.protocol_version, packet) do
      {:ok, data} ->
        # Enforce server's maximum_packet_size (MQTT 5.0 §3.2.2.3.6)
        if state.server_maximum_packet_size &&
             :erlang.iolist_size(data) > state.server_maximum_packet_size do
          {:error, :packet_too_large}
        else
          socket_send(state, data)
        end

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

  defp socket_send(%{transport: :ws, socket: socket}, data) do
    :gen_tcp.send(socket, MqttX.Client.WebSocket.encode_frame(data))
  end

  defp socket_send(%{transport: :wss, socket: socket}, data) do
    :ssl.send(socket, MqttX.Client.WebSocket.encode_frame(data))
  end

  # Pick the next packet ID, skipping IDs currently in flight (§2.2.1: in-flight
  # IDs must be unique). Bounded by 65535 iterations.
  defp next_packet_id(state) do
    next_packet_id(state, 0)
  end

  defp next_packet_id(state, attempts) when attempts < 65_536 do
    id = state.packet_id
    next_id = if id >= 65_535, do: 1, else: id + 1
    state = %{state | packet_id: next_id}

    if Map.has_key?(state.pending_acks, {:tx, id}) or
         Map.has_key?(state.pending_acks, {:rx, id}) do
      next_packet_id(state, attempts + 1)
    else
      {id, state}
    end
  end

  defp next_packet_id(state, _attempts) do
    # All 65k IDs in use — fall back to advancing one slot. The caller will hit
    # the broker's flow-control limit long before this.
    id = state.packet_id
    next_id = if id >= 65_535, do: 1, else: id + 1
    {id, %{state | packet_id: next_id}}
  end

  defp schedule_reconnect(state) do
    # Cancel any pending reconnect so multiple disconnect events (e.g.
    # tcp_closed + tcp_error) don't stack timers.
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    {delay, backoff} = Backoff.next(state.backoff)
    Logger.info("[MqttX.Client] Reconnecting in #{delay}ms")
    timer = Process.send_after(self(), :reconnect, delay)
    %{state | backoff: backoff, reconnect_timer: timer}
  end

  defp arm_pingresp_timer(%{keepalive: 0}), do: nil

  defp arm_pingresp_timer(state) do
    if state.pingresp_timer, do: Process.cancel_timer(state.pingresp_timer)
    Process.send_after(self(), :pingresp_timeout, state.keepalive * 1500)
  end

  defp cancel_pingresp_timer(state) do
    if state.pingresp_timer, do: Process.cancel_timer(state.pingresp_timer)
    %{state | pingresp_timer: nil}
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

    {to_retry, dropped_count, pending} =
      Enum.reduce(state.pending_acks, {[], 0, state.pending_acks}, fn
        {{:tx, packet_id} = key, %{packet: packet, timestamp: ts, retries: retries} = entry},
        {retry, dropped, acc} ->
          age = now - ts

          cond do
            # Message expired and exceeded max retries - remove it
            age > state.retry_interval and retries >= @max_retries ->
              Logger.warning(
                "[MqttX.Client] Dropping packet #{packet_id} after #{retries} retries"
              )

              {retry, dropped + 1, Map.delete(acc, key)}

            # Message expired - retry it
            age > state.retry_interval ->
              updated_entry = %{entry | timestamp: now, retries: retries + 1}

              {[{packet_id, packet, entry.phase} | retry], dropped,
               Map.put(acc, key, updated_entry)}

            # Message not expired yet
            true ->
              {retry, dropped, acc}
          end

        # Skip received messages (rx) - they don't need retry. Reducer accumulator
        # is a 3-tuple, so we must return the full shape (previously returned `acc`
        # — which crashed with MatchError once both rx and tx entries coexisted).
        _other, {retry, dropped, acc} ->
          {retry, dropped, acc}
      end)

    # Resend expired messages with dup flag
    Enum.each(to_retry, fn {packet_id, packet, phase} ->
      resend_packet(state, packet_id, packet, phase)
    end)

    %{
      state
      | pending_acks: pending,
        inflight_tx_count: max(0, state.inflight_tx_count - dropped_count)
    }
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

  defp close_socket(%{transport: :ws, socket: socket}) do
    :gen_tcp.send(socket, MqttX.Client.WebSocket.encode_close())
    :gen_tcp.close(socket)
  end

  defp close_socket(%{transport: :wss, socket: socket}) do
    :ssl.send(socket, MqttX.Client.WebSocket.encode_close())
    :ssl.close(socket)
  end

  # Guard against socket already torn down (e.g. inside a server-initiated
  # DISCONNECT path that closed the socket while the same TCP packet was being
  # processed).
  defp set_socket_active(%{socket: nil}), do: :ok

  defp set_socket_active(%{transport: transport, socket: socket})
       when transport in [:tcp, :ws] do
    :inet.setopts(socket, active: :once)
  end

  defp set_socket_active(%{transport: transport, socket: socket})
       when transport in [:ssl, :wss] do
    :ssl.setopts(socket, active: :once)
  end

  defp notify_handler(%{handler: nil} = state, _event, _data), do: state

  defp notify_handler(
         %{handler: handler, handler_state: hstate, handler_has_handle_mqtt_event: true} = state,
         event,
         data
       ) do
    new_hstate = handler.handle_mqtt_event(event, data, hstate)
    %{state | handler_state: new_hstate}
  end

  defp notify_handler(state, _event, _data), do: state

  # Enhanced AUTH callback — handler can return {:continue, auth_data} or :ok
  defp notify_handler_auth(%{handler: handler, handler_state: hstate} = state, reason_code, props)
       when not is_nil(handler) do
    if function_exported?(handler, :handle_auth, 3) do
      case handler.handle_auth(reason_code, props, hstate) do
        {:continue, auth_data, new_hstate} ->
          {:continue, auth_data, %{state | handler_state: new_hstate}}

        {:ok, new_hstate} ->
          {:ok, %{state | handler_state: new_hstate}}
      end
    else
      {:ok, state}
    end
  end

  defp notify_handler_auth(state, _reason_code, _props), do: {:ok, state}

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
    if not is_nil(state.session_store) and not state.clean_session do
      session = %{
        packet_id: state.packet_id,
        pending_acks: state.pending_acks,
        subscriptions: state.subscriptions
      }

      state.session_store.save(state.client_id, session, state.session_store_state)
    end
  end

  # ============================================================================
  # Will Message Helper
  # ============================================================================

  defp build_will(opts) do
    case Keyword.get(opts, :will_topic) do
      nil ->
        nil

      topic ->
        %{
          topic: topic,
          payload: Keyword.get(opts, :will_payload, <<>>),
          qos: Keyword.get(opts, :will_qos, 0),
          retain: Keyword.get(opts, :will_retain, false),
          properties: Keyword.get(opts, :will_properties, %{})
        }
    end
  end

  # ============================================================================
  # Flow Control Helpers (MQTT 5.0)
  # ============================================================================

  # Check if we can send another QoS 1/2 message.
  # Respects both the broker's receive_maximum (MQTT 5.0) and the local max_inflight cap
  # to prevent unbounded pending_acks growth.
  defp can_send_qos_message?(state) do
    broker_max = state.receive_maximum || 65535
    local_max = state.max_inflight || @default_max_inflight
    max_allowed = min(broker_max, local_max)
    state.inflight_tx_count < max_allowed
  end

  # ============================================================================
  # Topic Alias Helpers (MQTT 5.0)
  # ============================================================================

  # Apply outgoing topic alias for PUBLISH (MQTT 5.0)
  # If server supports topic aliases, reuse alias for repeated topics to save bandwidth
  defp apply_outgoing_topic_alias(topic, properties, %{server_topic_alias_maximum: max} = state)
       when max > 0 and not is_map_key(properties, :topic_alias) do
    case Map.get(state.topic_to_alias, topic) do
      nil when state.next_alias <= max ->
        # Assign new alias: send topic + alias (server learns the mapping)
        alias_id = state.next_alias
        new_props = Map.put(properties, :topic_alias, alias_id)
        new_map = Map.put(state.topic_to_alias, topic, alias_id)
        {topic, new_props, %{state | topic_to_alias: new_map, next_alias: alias_id + 1}}

      nil ->
        # All aliases used, send normally
        {topic, properties, state}

      alias_id ->
        # Reuse existing alias: send empty topic + alias
        new_props = Map.put(properties, :topic_alias, alias_id)
        {"", new_props, state}
    end
  end

  defp apply_outgoing_topic_alias(topic, properties, state) do
    {topic, properties, state}
  end

  # Handle WebSocket framed data — decode frames and append payloads to MQTT
  # buffer. Threads the fragmentation state across reads so a multi-frame
  # message split across TCP boundaries is reassembled correctly.
  defp handle_ws_data(data, state) do
    ws_buf = state.ws_buffer <> data

    case MqttX.Client.WebSocket.decode_frames(ws_buf, state.ws_frag) do
      {:ok, payloads, rest, frag} ->
        mqtt_data = IO.iodata_to_binary(payloads)

        buffer =
          case state.buffer do
            <<>> -> mqtt_data
            buf -> buf <> mqtt_data
          end

        %{state | buffer: buffer, ws_buffer: rest, ws_frag: frag}

      {:close, payloads} ->
        mqtt_data = IO.iodata_to_binary(payloads)

        buffer =
          case state.buffer do
            <<>> -> mqtt_data
            buf -> buf <> mqtt_data
          end

        %{state | buffer: buffer, ws_buffer: <<>>, ws_frag: MqttX.Client.WebSocket.initial_frag()}
    end
  end

  # Log reason_string from server responses (MQTT 5.0)
  defp log_reason_string(%{reason_string: reason}) when is_binary(reason) and reason != "" do
    Logger.info("[MqttX.Client] Server reason: #{reason}")
  end

  defp log_reason_string(_props), do: :ok

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
