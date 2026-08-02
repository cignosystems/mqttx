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

  # Ceiling on a single inbound MQTT packet (1 MiB). Mirrors the server-side
  # cap: a hostile or compromised broker can otherwise declare a ~256 MB
  # remaining length and make the client buffer toward it.
  @default_max_packet_size 1_048_576

  defstruct [
    :host,
    :port,
    :client_id,
    # The client id as configured, captured once in init/1 and never reassigned.
    # `client_id` can be replaced by the broker's Assigned Client Identifier, so
    # it must not select which persisted session record we read or write.
    :session_key,
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
    # HTTP CONNECT proxy: [host:, port:, auth: {user, pass}] or nil (direct)
    proxy: nil,
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
    # Server sent a WS Close frame; tear down after draining the buffer
    ws_close_pending: false,
    # Fatal inbound framing error detected while buffering (torn down on the
    # next pass through the data handler)
    inbound_error: nil,
    # Ceiling on a single inbound MQTT packet; nil disables (see :max_packet_size)
    max_packet_size: @default_max_packet_size,
    # Pending callers waiting for SUBACK/UNSUBACK
    pending_subs: %{},
    handler_has_handle_mqtt_event: false,
    inflight_tx_count: 0,
    # Outstanding PINGREQ deadline timer (close connection if no PINGRESP arrives)
    pingresp_timer: nil,
    # Pending reconnect timer (avoid stacking timers when several events fire)
    reconnect_timer: nil,
    # CONNECT sent, CONNACK not yet received (handshake runs through the
    # normal handle_info loop — never a blocking receive)
    connecting: false,
    # Total-handshake deadline timer (not reset by AUTH rounds)
    connack_timer: nil,
    # Generation ref pairing a :connack_timeout with the handshake that armed it
    connack_ref: nil,
    # Telemetry span carried across the async handshake
    connect_telemetry: nil,
    # Monotonic submission counter so in-flight QoS 1/2 messages can be
    # resent in original order on session resumption (§4.6)
    pending_seq: 0,
    # Callers of MqttX.Client.connect/1 waiting for the first CONNACK outcome
    connect_waiters: []
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
  - `:proxy` - HTTP CONNECT proxy for any transport, e.g.
    `[host: "proxy.corp", port: 3128, auth: {"user", "pass"}]` (`:port`
    defaults to 3128, `:auth` is optional Basic auth). TLS is negotiated with
    the *target* host through the tunnel, so certificate verification and SNI
    are unaffected by the proxy.
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
    # Validate required options up front so callers get {:error, _} per the
    # documented contract instead of a GenServer init crash (KeyError).
    case Enum.find([:host, :client_id], &(not Keyword.has_key?(opts, &1))) do
      nil -> GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      missing -> {:error, {:missing_option, missing}}
    end
  end

  @doc false
  # `restart: :transient` so an explicit `disconnect/2` ({:stop, :normal})
  # actually stops a supervised client instead of being resurrected by the
  # DynamicSupervisor and immediately reconnecting to the broker.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
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

  @doc false
  # Block the CALLER (never the connection process) until the first connection
  # attempt resolves. Returns :ok once CONNACK has been accepted, or
  # {:error, reason} if the attempt failed. Used by MqttX.Client.connect/1 so
  # that `connect` followed immediately by `subscribe`/`publish` works — the
  # contract callers relied on before the handshake became event-driven.
  @spec await_connect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_connect(pid, timeout \\ @connect_timeout * 2 + 1_000) do
    GenServer.call(pid, :await_connect, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:normal, _} -> {:error, :closed}
    :exit, {:noproc, _} -> {:error, :closed}
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
        {1, %{}, %{}}
      end

    handler = Keyword.get(opts, :handler)

    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, default_port),
      client_id: client_id,
      session_key: client_id,
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
      proxy: Keyword.get(opts, :proxy),
      max_packet_size:
        case Keyword.get(opts, :max_packet_size, @default_max_packet_size) do
          :infinity -> nil
          size when is_integer(size) and size > 0 -> size
          _ -> @default_max_packet_size
        end,
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
      # Code.ensure_loaded?/1 first: in dev/iex the handler module may simply
      # not be loaded yet, and a bare function_exported?/3 would silently
      # classify it as callback-less, discarding every event forever.
      handler_has_handle_mqtt_event:
        if(handler,
          do:
            Code.ensure_loaded?(handler) and
              function_exported?(handler, :handle_mqtt_event, 3),
          else: false
        )
    }

    # Register with ClientRegistry for lookup by client_id
    Registry.register(MqttX.ClientRegistry, client_id, %{host: state.host, port: state.port})

    # Trap exits so terminate/2 runs on supervisor/VM shutdown: without it a
    # :shutdown kill skips the clean DISCONNECT (broker publishes the will)
    # and never saves the session.
    Process.flag(:trap_exit, true)

    # Attempt initial connection
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.connected and state.socket do
      send_packet(state, %{type: :disconnect, reason_code: 0x00, properties: %{}})
    end

    close_socket(state)
    save_session(state)
    :ok
  end

  @impl true
  def handle_call({:publish, topic, payload, opts}, _from, state) do
    if state.connected do
      qos = Keyword.get(opts, :qos, 0)
      retain = Keyword.get(opts, :retain, false)
      properties = Keyword.get(opts, :properties, %{})

      cond do
        # An invalid QoS used to encode a malformed packet and then crash
        # the whole connection with a CaseClauseError.
        qos not in 0..2 ->
          {:reply, {:error, :invalid_qos}, state}

        # Check flow control for QoS 1/2 (MQTT 5.0 receive_maximum)
        qos > 0 and not can_send_qos_message?(state) ->
          {:reply, {:error, :flow_control}, state}

        true ->
          {packet_id, state} =
            if qos > 0 do
              case next_packet_id(state) do
                {:ok, id, state} -> {id, state}
                {:error, reason} -> throw({:reply_error, reason})
              end
            else
              {nil, state}
            end

          # Apply outgoing topic alias (MQTT 5.0)
          {publish_topic, publish_properties, state} =
            MqttX.Client.TopicAlias.apply_outgoing(topic, properties, state)

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

              # Track pending acks for QoS 1 and 2. The stored packet keeps the
              # ORIGINAL topic and properties (no topic alias): aliases are
              # per-connection (§3.3.2.3.4), so a retry after reconnect must
              # not replay stale alias state.
              state =
                if qos == 0 do
                  state
                else
                  phase = if qos == 1, do: :puback_pending, else: :pubrec_pending

                  retry_packet = %{packet | topic: topic, properties: properties}

                  pending =
                    Map.put(state.pending_acks, {:tx, packet_id}, %{
                      phase: phase,
                      packet: retry_packet,
                      timestamp: System.monotonic_time(:millisecond),
                      telemetry_meta: telemetry_meta,
                      retries: 0,
                      seq: state.pending_seq
                    })

                  %{
                    state
                    | pending_acks: pending,
                      inflight_tx_count: state.inflight_tx_count + 1,
                      pending_seq: state.pending_seq + 1
                  }
                end

              {:reply, :ok, state}

            {:error, _} = err ->
              {:reply, err, state}
          end
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  catch
    {:reply_error, reason} -> {:reply, {:error, reason}, state}
  end

  def handle_call({:subscribe, topics, opts}, from, state) do
    if state.connected do
      qos = Keyword.get(opts, :qos, 0)
      no_local = Keyword.get(opts, :no_local, false)
      retain_as_published = Keyword.get(opts, :retain_as_published, false)
      retain_handling = Keyword.get(opts, :retain_handling, 0)

      {packet_id, state} =
        case next_packet_id(state) do
          {:ok, id, state} -> {id, state}
          {:error, reason} -> throw({:reply_error, reason})
        end

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

          pending =
            Map.put(
              state.pending_subs,
              packet_id,
              {:subscribe, from, monitor, topic_list, subscribe_props}
            )

          {:noreply, %{state | pending_subs: pending}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  catch
    {:reply_error, reason} -> {:reply, {:error, reason}, state}
  end

  def handle_call({:unsubscribe, topics}, from, state) do
    if state.connected do
      {packet_id, state} =
        case next_packet_id(state) do
          {:ok, id, state} -> {id, state}
          {:error, reason} -> throw({:reply_error, reason})
        end

      packet = %{
        type: :unsubscribe,
        packet_id: packet_id,
        topics: topics
      }

      case send_packet(state, packet) do
        :ok ->
          {caller_pid, _} = from
          monitor = Process.monitor(caller_pid)

          pending =
            Map.put(state.pending_subs, packet_id, {:unsubscribe, from, monitor, topics})

          {:noreply, %{state | pending_subs: pending}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  catch
    {:reply_error, reason} -> {:reply, {:error, reason}, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call(:await_connect, _from, %{connected: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_connect, from, state) do
    {:noreply, %{state | connect_waiters: [from | state.connect_waiters]}}
  end

  @impl true
  def handle_cast({:disconnect, opts}, state) do
    reason_code = Keyword.get(opts, :reason_code, 0)
    properties = Keyword.get(opts, :properties, %{})

    Telemetry.client_disconnect(%{client_id: state.client_id, reason: :normal})

    # Only send DISCONNECT if there is a live socket — calling this while
    # offline (reconnect backoff) used to crash on `:gen_tcp.send(nil, _)`.
    if state.connected and state.socket do
      send_packet(state, %{
        type: :disconnect,
        reason_code: reason_code,
        properties: properties
      })
    end

    close_socket(state)
    save_session(state)
    {:stop, :normal, %{state | connected: false, socket: nil}}
  end

  @impl true
  def handle_info(:connect, %{connecting: true} = state), do: {:noreply, state}
  def handle_info(:connect, %{connected: true} = state), do: {:noreply, state}

  def handle_info(:connect, state) do
    metadata = %{
      host: state.host,
      port: state.port,
      client_id: state.client_id,
      transport: state.transport
    }

    start_time = System.monotonic_time()
    Telemetry.client_connect_start(metadata)
    state = %{state | connect_telemetry: %{start_time: start_time, metadata: metadata}}

    # do_connect opens the socket (and performs the WS upgrade) and sends
    # CONNECT; the CONNACK/AUTH handshake is completed asynchronously via
    # handle_info so the GenServer keeps serving calls while connecting.
    case do_connect(state) do
      {:ok, state} ->
        # Ref-tag the deadline: a late :connack_timeout from a previous
        # connection generation must not tear down this handshake.
        ref = make_ref()
        connack_timer = Process.send_after(self(), {:connack_timeout, ref}, @connect_timeout)

        {:noreply,
         %{
           state
           | connecting: true,
             connack_timer: connack_timer,
             connack_ref: ref,
             buffer: <<>>
         }}

      {:error, reason} ->
        {:noreply, connect_failed(state, reason)}
    end
  end

  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  # Total-handshake deadline: CONNECT was sent but no CONNACK arrived in time.
  # AUTH exchanges do NOT re-arm this timer, so a broker trickling AUTH
  # packets cannot keep the handshake open indefinitely.
  def handle_info({:connack_timeout, ref}, %{connecting: true, connack_ref: ref} = state) do
    {:noreply, connect_failed(%{state | connack_timer: nil}, :timeout)}
  end

  # Stale deadline from an earlier generation (or we already connected)
  def handle_info({:connack_timeout, _ref}, state), do: {:noreply, state}

  # Deferred stop after a non-retryable CONNACK rejection (see connect_failed/2).
  def handle_info({:stop_client, _reason}, state) do
    {:stop, :normal, state}
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

  # Stale deadline from a previous connection generation — ignore.
  def handle_info(:pingresp_timeout, %{connected: false} = state), do: {:noreply, state}

  def handle_info(:pingresp_timeout, state) do
    Logger.warning("[MqttX.Client] PINGRESP timeout — closing socket")
    save_session(state)
    close_socket(state)
    state = %{state | connected: false, socket: nil, pingresp_timer: nil}
    state = cancel_conn_timers(state)
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

    state =
      cond do
        # A frame/packet above our ceiling — tear down rather than buffer it
        state.inbound_error != nil ->
          reason = state.inbound_error
          protocol_error_teardown(%{state | inbound_error: nil}, reason)

        oversized_inbound?(state) ->
          protocol_error_teardown(state, :packet_too_large)

        state.connecting ->
          process_connack_buffer(state)

        true ->
          process_buffer(state)
      end

    state =
      if state.ws_close_pending and state.socket do
        # Server initiated the WS close handshake: reply with a close frame
        # and treat it like a remote disconnect.
        ws_socket_send(state, MqttX.Client.WebSocket.encode_close())
        save_session(state)
        close_socket(%{state | connected: false})
        state = %{state | connected: false, socket: nil, buffer: <<>>, ws_close_pending: false}
        state = cancel_conn_timers(state)
        state = notify_handler(state, :disconnected, :closed)
        schedule_reconnect(state)
      else
        %{state | ws_close_pending: false}
      end

    set_socket_active(state)
    {:noreply, state}
  end

  # Handle socket closed for TCP, SSL, WS, WSS
  def handle_info({closed, socket}, %{socket: socket} = state)
      when closed in [:tcp_closed, :ssl_closed] do
    if state.connecting do
      # Dropped during the handshake — a connect failure, not a disconnect
      {:noreply, connect_failed(%{state | socket: nil}, :closed)}
    else
      Logger.info("[MqttX.Client] Connection closed")
      save_session(state)
      state = %{state | connected: false, socket: nil}
      state = cancel_conn_timers(state)
      state = notify_handler(state, :disconnected, :closed)
      state = schedule_reconnect(state)
      {:noreply, state}
    end
  end

  # Handle socket errors for both TCP and SSL
  def handle_info({error, socket, reason}, %{socket: socket} = state)
      when error in [:tcp_error, :ssl_error] do
    if state.connecting do
      {:noreply, connect_failed(%{state | socket: nil}, {:error, reason})}
    else
      Logger.warning("[MqttX.Client] Socket error: #{inspect(reason)}")
      save_session(state)
      state = %{state | connected: false, socket: nil}
      state = cancel_conn_timers(state)
      state = notify_handler(state, :disconnected, {:error, reason})
      state = schedule_reconnect(state)
      {:noreply, state}
    end
  end

  # Caller of subscribe/unsubscribe died (e.g. GenServer.call timed out and
  # caller exited). Drop the matching pending_subs entry so we don't leak.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    pending =
      state.pending_subs
      |> Enum.reject(fn {_packet_id, entry} -> elem(entry, 2) == monitor end)
      |> Map.new()

    {:noreply, %{state | pending_subs: pending}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # PRIVATE FUNCTIONS
  # ============================================================================

  # All transports acquire a raw TCP socket first (directly, or through an
  # HTTP CONNECT proxy when `:proxy` is configured), then layer TLS and/or
  # the WebSocket upgrade on top.

  defp do_connect(%{transport: :tcp} = state) do
    case open_tcp(state) do
      {:ok, socket} ->
        :inet.setopts(socket, active: :once)
        send_connect(%{state | socket: socket})

      {:error, _} = err ->
        err
    end
  end

  defp do_connect(%{transport: :ssl} = state) do
    ssl_opts = [{:active, :once} | secure_ssl_opts(state.host, state.ssl_opts)]

    with {:ok, tcp_socket} <- open_tcp(state),
         {:ok, socket} <- ssl_upgrade(tcp_socket, ssl_opts) do
      send_connect(%{state | socket: socket})
    end
  end

  defp do_connect(%{transport: :ws} = state) do
    case open_tcp(state) do
      {:ok, socket} ->
        case MqttX.Client.WebSocket.upgrade(socket, :tcp, state.host, state.ws_path) do
          :ok ->
            :inet.setopts(socket, active: :once)
            send_connect(reset_ws_state(%{state | socket: socket}))

          {:error, _} = err ->
            :gen_tcp.close(socket)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_connect(%{transport: :wss} = state) do
    ssl_opts = [{:active, false} | secure_ssl_opts(state.host, state.ssl_opts)]

    with {:ok, tcp_socket} <- open_tcp(state),
         {:ok, socket} <- ssl_upgrade(tcp_socket, ssl_opts) do
      case MqttX.Client.WebSocket.upgrade(socket, :ssl, state.host, state.ws_path) do
        :ok ->
          :ssl.setopts(socket, active: :once)
          send_connect(reset_ws_state(%{state | socket: socket}))

        {:error, _} = err ->
          :ssl.close(socket)
          err
      end
    end
  end

  # A partial fragment from the previous connection must not leak into this
  # one's continuation frames
  defp reset_ws_state(state) do
    %{
      state
      | ws_buffer: <<>>,
        ws_frag: MqttX.Client.WebSocket.initial_frag(),
        ws_close_pending: false
    }
  end

  # Open the raw TCP socket (passive mode) — directly, or tunneled through
  # an HTTP CONNECT proxy (RFC 9110 §9.3.6) when `:proxy` is configured.
  defp open_tcp(%{proxy: nil} = state) do
    :gen_tcp.connect(
      to_charlist(state.host),
      state.port,
      [:binary, active: false],
      @connect_timeout
    )
  end

  defp open_tcp(%{proxy: proxy} = state) do
    MqttX.Client.Proxy.connect(state.host, state.port, proxy, @connect_timeout)
  end

  defp ssl_upgrade(tcp_socket, ssl_opts) do
    case :ssl.connect(tcp_socket, ssl_opts, @connect_timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} = err -> err
    end
  end

  # Secure-by-default TLS: verification against the OS trust store with SNI
  # and HTTPS-style hostname checking. User-supplied `:ssl_opts` are merged
  # *over* this baseline, so anything (including `verify: :verify_none`) can
  # still be overridden explicitly — an insecure setting is now a visible
  # choice instead of the silent default.
  defp secure_ssl_opts(host, user_opts) do
    user_opts = user_opts || []

    base = [
      verify: :verify_peer,
      depth: 4,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      secure_renegotiate: true,
      server_name_indication: to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    base =
      if Keyword.has_key?(user_opts, :cacerts) or Keyword.has_key?(user_opts, :cacertfile) do
        base
      else
        base ++ [cacerts: :public_key.cacerts_get()]
      end

    merged = Keyword.merge(base, user_opts)

    if Keyword.get(merged, :verify) == :verify_none do
      Logger.warning(
        "[MqttX.Client] TLS certificate verification is DISABLED (verify: :verify_none) — " <>
          "connections are vulnerable to man-in-the-middle attacks"
      )
    end

    merged
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
      :ok ->
        {:ok, state}

      {:error, _} = err ->
        close_socket(state)
        err
    end
  end

  # Decode CONNACK/AUTH from the buffer while in the :connecting state.
  # Runs inside the normal handle_info loop — never a blocking receive.
  defp process_connack_buffer(state) do
    case Codec.decode(state.protocol_version, state.buffer) do
      {:ok, {%{type: :connack, reason_code: 0} = connack, rest}} ->
        finalize_connection(connack, %{state | buffer: rest})

      {:ok, {%{type: :connack, reason_code: code} = connack, _rest}} ->
        props = Map.get(connack, :properties, %{})
        server_ref = Map.get(props, :server_reference)
        log_reason_string(props)

        if server_ref do
          Logger.info("[MqttX.Client] Server reference: #{server_ref}")
        end

        connect_failed(state, {:connack_error, code, %{server_reference: server_ref}})

      # Enhanced AUTH continuation during connect (MQTT 5.0 §4.12). Note the
      # connack deadline keeps running — AUTH rounds don't extend it.
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

            process_connack_buffer(%{state | buffer: rest})

          {:ok, state} ->
            process_connack_buffer(%{state | buffer: rest})
        end

      {:ok, {_other, _rest}} ->
        # §3.2.0-1: the first packet from the server MUST be CONNACK (or AUTH)
        connect_failed(state, :protocol_error)

      {:error, :incomplete} ->
        state

      {:error, reason} ->
        connect_failed(state, reason)
    end
  end

  defp finalize_connection(connack, state) do
    Logger.info("[MqttX.Client] Connected to #{state.host}:#{state.port}")

    if state.connack_timer, do: Process.cancel_timer(state.connack_timer)

    props = Map.get(connack, :properties, %{})
    session_present = Map.get(connack, :session_present, false)

    # MQTT-3.2.2-2: server MUST NOT report session_present=true if we
    # asked for clean_start. Surface a warning; the handler can decide
    # whether to abort.
    if state.clean_session and session_present do
      Logger.warning(
        "[MqttX.Client] Broker returned session_present=true despite clean_session=true (MQTT-3.2.2-2)"
      )
    end

    emit_connect_stop_telemetry(state)

    # §4.4: on session resumption immediately resend unacknowledged QoS 1/2
    # state in original order; on a fresh session, discard it. And if the
    # broker did not resume our session, replay every tracked subscription
    # or the client is silently deaf after reconnect.
    state =
      state
      |> apply_connack_settings(props)
      |> sync_inflight_after_connect(session_present)
      |> notify_handler(:connected, %{properties: props, session_present: session_present})

    state = if session_present, do: state, else: resubscribe_all(state)
    state = reply_to_connect_waiters(state, :ok)

    # Process any packets that arrived right behind the CONNACK
    if state.buffer != <<>>, do: process_buffer(state), else: state
  end

  # Apply the settings the CONNACK negotiated: server overrides for keepalive
  # (§3.2.2.3.14) and client id (§3.2.2.3.7), flow-control and packet-size
  # limits, and fresh per-connection topic-alias tables (§3.3.2.3.4).
  defp apply_connack_settings(state, props) do
    keepalive = Map.get(props, :server_keep_alive) || state.keepalive
    client_id = assigned_client_id(props, state)

    keepalive_timer =
      if keepalive > 0,
        do: Process.send_after(self(), :keepalive, keepalive * 1000),
        else: nil

    %{
      state
      | connected: true,
        connecting: false,
        connack_timer: nil,
        connack_ref: nil,
        connect_telemetry: nil,
        backoff: Backoff.reset(state.backoff),
        keepalive_timer: keepalive_timer,
        retry_timer: Process.send_after(self(), :check_inflight, state.retry_interval),
        pingresp_timer: nil,
        keepalive: keepalive,
        client_id: client_id,
        topic_alias_maximum: Map.get(props, :topic_alias_maximum),
        receive_maximum: Map.get(props, :receive_maximum, 65535),
        server_maximum_packet_size: Map.get(props, :maximum_packet_size),
        server_topic_alias_maximum: Map.get(props, :topic_alias_maximum, 0),
        topic_to_alias: %{},
        next_alias: 1,
        alias_to_topic: %{}
    }
  end

  # §3.2.2.3.7: the server assigns a Client Identifier only when the client sent
  # a zero-length one. Honouring it unconditionally let any broker rename this
  # connection to another client's id, which used to select the session-store
  # record we wrote — see `session_key`.
  defp assigned_client_id(props, %{client_id: configured} = state)
       when configured in [nil, ""] do
    Map.get(props, :assigned_client_identifier) || state.client_id
  end

  defp assigned_client_id(props, state) do
    case Map.get(props, :assigned_client_identifier) do
      nil ->
        state.client_id

      assigned when assigned != state.client_id ->
        Logger.warning(
          "[MqttX.Client] Broker sent an Assigned Client Identifier " <>
            "(#{inspect(assigned)}) although we supplied #{inspect(state.client_id)}; " <>
            "ignoring it (MQTT 5.0 §3.2.2.3.7)"
        )

        state.client_id

      _same ->
        state.client_id
    end
  end

  defp emit_connect_stop_telemetry(state) do
    if telem = state.connect_telemetry do
      duration = System.monotonic_time() - telem.start_time
      Telemetry.client_connect_stop(duration, telem.metadata)
    end

    :ok
  end

  # A connection attempt failed (transport error, CONNACK rejection,
  # handshake timeout, protocol error before CONNACK).
  defp connect_failed(state, reason) do
    if state.connack_timer, do: Process.cancel_timer(state.connack_timer)
    close_socket(state)

    if telem = state.connect_telemetry do
      duration = System.monotonic_time() - telem.start_time
      Telemetry.client_connect_exception(duration, Map.put(telem.metadata, :reason, reason))
    end

    Logger.warning("[MqttX.Client] Connection failed: #{inspect(reason)}")

    state = reply_to_connect_waiters(state, {:error, reason})

    state = %{
      state
      | connecting: false,
        connack_timer: nil,
        connack_ref: nil,
        connect_telemetry: nil,
        socket: nil,
        buffer: <<>>
    }

    if fatal_connack?(state, reason) do
      # Bad credentials / not authorized / banned / unsupported version:
      # retrying can never succeed — hammering the broker just invites rate
      # limiting. Notify the handler and stop.
      Logger.error(
        "[MqttX.Client] Broker rejected CONNECT with a non-retryable reason — giving up: #{inspect(reason)}"
      )

      state = notify_handler(state, :disconnected, reason)
      send(self(), {:stop_client, reason})
      state
    else
      schedule_reconnect(state)
    end
  end

  # CONNACK reason codes for which reconnecting cannot help (§3.2.2.2 for v5,
  # §3.2.2.3 for v3.1.1): unsupported version, invalid client id, bad
  # credentials, not authorized, banned, bad authentication method.
  @fatal_connack_v5 [0x84, 0x85, 0x86, 0x87, 0x8A, 0x8C]
  @fatal_connack_v3 [0x01, 0x02, 0x04, 0x05]

  defp fatal_connack?(state, {:connack_error, code, _info}) do
    if state.protocol_version == 5 do
      code in @fatal_connack_v5
    else
      code in @fatal_connack_v3
    end
  end

  defp fatal_connack?(_state, _reason), do: false

  # Resynchronize in-flight QoS 1/2 state with the (possibly resumed) session.
  defp sync_inflight_after_connect(state, true = _session_present) do
    now = System.monotonic_time(:millisecond)

    tx_entries =
      for {{:tx, packet_id}, entry} <- state.pending_acks, do: {packet_id, entry}

    # Resend promptly, in original submission order (§4.4, §4.6)
    tx_entries
    |> Enum.sort_by(fn {_id, entry} -> Map.get(entry, :seq, 0) end)
    |> Enum.each(fn {packet_id, entry} ->
      resend_packet(state, packet_id, entry.packet, entry.phase)
    end)

    # Refresh timestamps so the periodic retry loop measures from this
    # resend (also repairs monotonic timestamps loaded from a previous VM)
    pending =
      Map.new(state.pending_acks, fn
        {{:tx, _} = key, entry} -> {key, %{entry | timestamp: now}}
        other -> other
      end)

    %{state | pending_acks: pending, inflight_tx_count: length(tx_entries)}
  end

  defp sync_inflight_after_connect(state, false = _session_present) do
    dropped = map_size(state.pending_acks)

    if dropped > 0 do
      Logger.warning(
        "[MqttX.Client] Broker started a fresh session — discarding #{dropped} in-flight QoS message(s) (MQTT-3.2.2-4)"
      )
    end

    %{state | pending_acks: %{}, inflight_tx_count: 0}
  end

  defp process_buffer(state) do
    case Codec.decode(state.protocol_version, state.buffer) do
      {:ok, {packet, rest}} ->
        state = handle_packet(packet, state)

        if state.socket do
          process_buffer(%{state | buffer: rest})
        else
          # handle_packet tore the connection down (protocol error, server
          # DISCONNECT) — don't keep decoding against a dead connection.
          %{state | buffer: <<>>}
        end

      {:error, :incomplete} ->
        state

      {:error, reason} ->
        # §4.13: a malformed packet requires closing the connection. Leaving
        # the bad bytes buffered would wedge decoding forever while the buffer
        # grows with every subsequent TCP segment.
        protocol_error_teardown(state, reason)
    end
  end

  # Reject a packet whose DECLARED remaining length exceeds our ceiling before
  # the body is buffered (§3.1.2.11.4), mirroring the server-side guard.
  defp oversized_inbound?(%{max_packet_size: nil}), do: false

  defp oversized_inbound?(%{max_packet_size: max, buffer: buffer}) do
    case Codec.declared_length(buffer) do
      {:ok, declared} -> declared > max
      _ -> false
    end
  end

  defp reply_to_connect_waiters(%{connect_waiters: []} = state, _result), do: state

  defp reply_to_connect_waiters(state, result) do
    Enum.each(state.connect_waiters, &GenServer.reply(&1, result))
    %{state | connect_waiters: []}
  end

  # Close the connection on a protocol violation and schedule a reconnect.
  defp protocol_error_teardown(state, reason) do
    Logger.warning("[MqttX.Client] Protocol error: #{inspect(reason)} — closing connection")

    save_session(state)
    close_socket(state)
    state = %{state | connected: false, socket: nil, buffer: <<>>}
    state = cancel_conn_timers(state)
    state = notify_handler(state, :disconnected, {:protocol_error, reason})
    schedule_reconnect(state)
  end

  defp handle_packet(%{type: :publish} = packet, state) do
    # Handle topic alias (MQTT 5.0)
    case MqttX.Client.TopicAlias.resolve_incoming(packet, state) do
      {:ok, topic, state} ->
        handle_publish_packet(%{packet | topic: topic}, topic, state)

      {:error, reason} ->
        protocol_error_teardown(state, reason)
    end
  end

  defp handle_packet(%{type: :puback} = packet, state) do
    log_reason_string(Map.get(packet, :properties, %{}))
    reason_code = Map.get(packet, :reason_code, 0)

    # QoS 1 complete (or rejected): emit telemetry and remove from pending
    state =
      case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
        %{timestamp: ts, telemetry_meta: meta} = entry ->
          duration = System.monotonic_time(:millisecond) - ts

          if reason_code >= 0x80 do
            # Broker rejected the publish (0x87 Not authorized, 0x97 Quota
            # exceeded, ...) — surface it instead of reporting success.
            Logger.warning(
              "[MqttX.Client] PUBLISH #{packet.packet_id} rejected by broker: 0x#{Integer.to_string(reason_code, 16)}"
            )

            Telemetry.client_publish_error(duration, Map.put(meta, :reason_code, reason_code))
            notify_publish_error(state, entry, reason_code)
          else
            Telemetry.client_publish_stop(duration, meta)
            state
          end

        _ ->
          state
      end

    pending = Map.delete(state.pending_acks, {:tx, packet.packet_id})
    %{state | pending_acks: pending, inflight_tx_count: max(0, state.inflight_tx_count - 1)}
  end

  # QoS 2 - received PUBREC for our outgoing PUBLISH
  defp handle_packet(%{type: :pubrec} = packet, state) do
    reason_code = Map.get(packet, :reason_code, 0)

    case Map.get(state.pending_acks, {:tx, packet.packet_id}) do
      %{phase: :pubrec_pending} = entry when reason_code >= 0x80 ->
        # §4.3.3: an error PUBREC aborts the QoS 2 flow — discard the message
        # and do NOT send PUBREL.
        Logger.warning(
          "[MqttX.Client] QoS 2 PUBLISH #{packet.packet_id} rejected by broker: 0x#{Integer.to_string(reason_code, 16)}"
        )

        state = notify_publish_error(state, entry, reason_code)
        pending = Map.delete(state.pending_acks, {:tx, packet.packet_id})
        %{state | pending_acks: pending, inflight_tx_count: max(0, state.inflight_tx_count - 1)}

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
        # PUBREL for an id we no longer track: our PUBCOMP was lost and the
        # broker retransmitted PUBREL (§4.3.3). Answer PUBCOMP again (0x92 in
        # v5) — staying silent would leave the broker retrying forever and,
        # depending on the broker, redelivering the message.
        pubcomp =
          if state.protocol_version >= 5 do
            %{type: :pubcomp, packet_id: packet.packet_id, reason_code: 0x92, properties: %{}}
          else
            %{type: :pubcomp, packet_id: packet.packet_id}
          end

        send_packet(state, pubcomp)
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
      {{:subscribe, from, monitor, topic_list, sub_props}, pending} ->
        if monitor, do: Process.demonitor(monitor, [:flush])
        # Check if any subscription was rejected
        reply =
          if Enum.all?(acks, &match?({:ok, _}, &1)) do
            {:ok, Enum.map(acks, fn {:ok, qos} -> qos end)}
          else
            {:error, {:subscription_refused, acks}}
          end

        if from, do: GenServer.reply(from, reply)

        # Track granted subscriptions so they can be replayed after a
        # reconnect that did not resume the server-side session.
        subscriptions =
          topic_list
          |> Enum.zip(acks)
          |> Enum.reduce(state.subscriptions, fn
            {%{topic: topic} = spec, {:ok, _granted_qos}}, acc ->
              Map.put(acc, topic, %{spec: Map.delete(spec, :topic), properties: sub_props})

            {_spec, _rejected}, acc ->
              acc
          end)

        %{state | pending_subs: pending, subscriptions: subscriptions}

      {nil, _} ->
        state
    end
  end

  defp handle_packet(%{type: :unsuback} = packet, state) do
    packet_id = packet.packet_id
    props = Map.get(packet, :properties, %{})
    log_reason_string(props)

    case Map.pop(state.pending_subs, packet_id) do
      {{:unsubscribe, from, monitor, topics}, pending} ->
        if monitor, do: Process.demonitor(monitor, [:flush])
        if from, do: GenServer.reply(from, :ok)
        subscriptions = Map.drop(state.subscriptions, topics)
        %{state | pending_subs: pending, subscriptions: subscriptions}

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
    state = %{state | connected: false, socket: nil}
    state = cancel_conn_timers(state)
    schedule_reconnect(state)
  end

  defp handle_packet(_packet, state) do
    state
  end

  defp handle_publish_packet(packet, topic, state) do
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
        # QoS 2: store message, send PUBREC, wait for PUBREL before delivering.
        # Bound the inbound in-flight set by our advertised Receive Maximum
        # (§3.3.4) — a broker exceeding it gets DISCONNECT 0x93.
        rx_count =
          Enum.count(state.pending_acks, fn
            {{:rx, _}, _} -> true
            _ -> false
          end)

        already_pending = Map.has_key?(state.pending_acks, {:rx, packet.packet_id})

        if not already_pending and rx_count >= inbound_receive_maximum(state) do
          if state.protocol_version >= 5 do
            send_packet(state, %{type: :disconnect, reason_code: 0x93, properties: %{}})
          end

          protocol_error_teardown(state, :receive_maximum_exceeded)
        else
          pending =
            Map.put(state.pending_acks, {:rx, packet.packet_id}, %{
              phase: :pubrec_sent,
              packet: packet
            })

          send_packet(state, %{type: :pubrec, packet_id: packet.packet_id})
          %{state | pending_acks: pending}
        end
    end
  end

  # The Receive Maximum we advertised in CONNECT (default: no limit per
  # spec = 65535).
  defp inbound_receive_maximum(state) do
    Map.get(state.connect_properties || %{}, :receive_maximum, 65_535)
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

    # PUBLISH, SUBSCRIBE and UNSUBSCRIBE share one packet-id space (§2.2.1),
    # so ids held by in-flight subscribe calls must be skipped too.
    if Map.has_key?(state.pending_acks, {:tx, id}) or
         Map.has_key?(state.pending_acks, {:rx, id}) or
         Map.has_key?(state.pending_subs, id) do
      next_packet_id(state, attempts + 1)
    else
      {:ok, id, state}
    end
  end

  defp next_packet_id(_state, _attempts) do
    # All 65535 ids are genuinely in use — fail cleanly instead of handing
    # out an id that would corrupt the matching in-flight entry.
    {:error, :packet_ids_exhausted}
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

  # A previous PINGREQ is still unanswered — keep its deadline. Re-arming on
  # every keepalive tick would push the deadline forever forward (1.0×K tick
  # vs 1.5×K deadline), so a dead link would never be detected.
  defp arm_pingresp_timer(%{pingresp_timer: timer}) when timer != nil, do: timer

  defp arm_pingresp_timer(state) do
    Process.send_after(self(), :pingresp_timeout, state.keepalive * 1500)
  end

  defp cancel_pingresp_timer(state) do
    if state.pingresp_timer, do: Process.cancel_timer(state.pingresp_timer)
    %{state | pingresp_timer: nil}
  end

  defp cancel_keepalive(state) do
    if state.keepalive_timer, do: Process.cancel_timer(state.keepalive_timer)
    %{state | keepalive_timer: nil}
  end

  defp cancel_retry_timer(state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  # Cancel every per-connection timer and fail in-flight subscribe callers.
  # Must run on ALL teardown paths — a pingresp deadline that survives into
  # the next connection generation would tear down a healthy socket, and a
  # SUBACK for a dead connection will never arrive, so blocked callers must
  # get {:error, :not_connected} now rather than a call timeout.
  defp cancel_conn_timers(state) do
    state
    |> cancel_keepalive()
    |> cancel_retry_timer()
    |> cancel_pingresp_timer()
    |> fail_pending_subs()
  end

  defp fail_pending_subs(%{pending_subs: pending} = state) when map_size(pending) == 0,
    do: state

  defp fail_pending_subs(state) do
    Enum.each(state.pending_subs, fn {_packet_id, entry} ->
      monitor = elem(entry, 2)
      from = elem(entry, 1)
      if monitor, do: Process.demonitor(monitor, [:flush])
      if from, do: GenServer.reply(from, {:error, :not_connected})
    end)

    %{state | pending_subs: %{}}
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

  # The WS close frame is best-effort and only worth sending on a socket we
  # believe is alive — `:ssl.send/2` on a half-open socket can block the
  # GenServer during teardown.
  defp close_socket(%{transport: :ws, socket: socket} = state) do
    if state.connected, do: :gen_tcp.send(socket, MqttX.Client.WebSocket.encode_close())
    :gen_tcp.close(socket)
  end

  defp close_socket(%{transport: :wss, socket: socket} = state) do
    if state.connected, do: :ssl.send(socket, MqttX.Client.WebSocket.encode_close())
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

  # Surface a broker-rejected QoS 1/2 publish to the handler as
  # (:publish_error, {topic, packet_id, reason_code}, state).
  defp notify_publish_error(state, entry, reason_code) do
    notify_handler(
      state,
      :publish_error,
      {entry.packet.topic, entry.packet.packet_id, reason_code}
    )
  end

  defp notify_handler(%{handler: nil} = state, _event, _data), do: state

  defp notify_handler(
         %{handler: handler, handler_state: hstate, handler_has_handle_mqtt_event: true} = state,
         event,
         data
       ) do
    # A raising handler must not take the connection (and all QoS state) down
    # with it — and for QoS 1 a crash before PUBACK would make the broker
    # redeliver the same poison message in a loop.
    new_hstate = handler.handle_mqtt_event(event, data, hstate)
    %{state | handler_state: new_hstate}
  rescue
    exception ->
      Logger.error(
        "[MqttX.Client] Handler #{inspect(state.handler)} raised on #{inspect(event)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      state
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
      {:ok, state} ->
        {module, state}

      {:error, reason} ->
        # The caller explicitly asked for persistence — never degrade it
        # silently.
        Logger.warning(
          "[MqttX.Client] Session store #{inspect(module)} failed to initialize " <>
            "(#{inspect(reason)}) — session persistence is DISABLED for this connection"
        )

        {nil, nil}
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

        subscriptions =
          case Map.get(session, :subscriptions, %{}) do
            # Sessions written before subscriptions were tracked stored []
            subs when is_list(subs) -> %{}
            subs when is_map(subs) -> subs
          end

        {packet_id, pending_acks, subscriptions}

      :not_found ->
        {1, %{}, %{}}

      {:error, reason} ->
        Logger.warning(
          "[MqttX.Client] Failed to load session for #{inspect(client_id)}: #{inspect(reason)} — starting fresh"
        )

        {1, %{}, %{}}
    end
  end

  # Replay all tracked subscriptions after a connection whose CONNACK carried
  # session_present=false (fresh server-side session). One SUBSCRIBE packet is
  # sent per distinct properties map so per-call subscription identifiers are
  # preserved. Replies go nowhere (from: nil) — these SUBACKs only refresh the
  # subscription tracking.
  defp resubscribe_all(%{subscriptions: subs} = state) when map_size(subs) == 0, do: state

  defp resubscribe_all(state) do
    Logger.info(
      "[MqttX.Client] Restoring #{map_size(state.subscriptions)} subscription(s) after reconnect"
    )

    state.subscriptions
    |> Enum.group_by(fn {_topic, %{properties: props}} -> props end)
    |> Enum.reduce(state, fn {props, entries}, acc ->
      {:ok, packet_id, acc} = next_packet_id(acc)

      topic_list =
        Enum.map(entries, fn {topic, %{spec: spec}} -> Map.put(spec, :topic, topic) end)

      packet = %{
        type: :subscribe,
        packet_id: packet_id,
        topics: topic_list,
        properties: props
      }

      case send_packet(acc, packet) do
        :ok ->
          pending =
            Map.put(acc.pending_subs, packet_id, {:subscribe, nil, nil, topic_list, props})

          %{acc | pending_subs: pending}

        {:error, reason} ->
          Logger.warning("[MqttX.Client] Failed to restore subscriptions: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp save_session(state) do
    if not is_nil(state.session_store) and not state.clean_session do
      session = %{
        packet_id: state.packet_id,
        pending_acks: state.pending_acks,
        subscriptions: state.subscriptions
      }

      # session_key, not client_id: the store is keyed by what we configured, so
      # a broker cannot direct this write at another client's record.
      case state.session_store.save(state.session_key, session, state.session_store_state) do
        {:error, reason} ->
          Logger.warning(
            "[MqttX.Client] Failed to persist session for #{inspect(state.session_key)}: #{inspect(reason)}"
          )

        _ ->
          :ok
      end
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

  # Handle WebSocket framed data — decode frames and append payloads to MQTT
  # buffer. Threads the fragmentation state across reads so a multi-frame
  # message split across TCP boundaries is reassembled correctly.
  defp handle_ws_data(data, state) do
    ws_buf = state.ws_buffer <> data

    case MqttX.Client.WebSocket.decode_frames(ws_buf, state.ws_frag) do
      {:error, reason} ->
        # Oversized frame — flag for teardown by the caller
        %{state | inbound_error: reason, ws_buffer: <<>>}

      {:ok, payloads, pings, rest, frag} ->
        # RFC 6455 §5.5.2: every Ping must be answered with a Pong echoing
        # its payload — proxies/LBs liveness-check WS connections this way.
        Enum.each(pings, fn ping_payload ->
          ws_socket_send(state, MqttX.Client.WebSocket.encode_pong(ping_payload))
        end)

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

        # Process the final payloads first; the data-handler clause tears the
        # connection down once the buffer has been drained.
        %{
          state
          | buffer: buffer,
            ws_buffer: <<>>,
            ws_frag: MqttX.Client.WebSocket.initial_frag(),
            ws_close_pending: true
        }
    end
  end

  defp ws_socket_send(%{transport: :ws, socket: socket}, frame) when socket != nil,
    do: :gen_tcp.send(socket, frame)

  defp ws_socket_send(%{transport: :wss, socket: socket}, frame) when socket != nil,
    do: :ssl.send(socket, frame)

  defp ws_socket_send(_state, _frame), do: :ok

  # Log reason_string from server responses (MQTT 5.0)
  defp log_reason_string(%{reason_string: reason}) when is_binary(reason) and reason != "" do
    Logger.info("[MqttX.Client] Server reason: #{reason}")
  end

  defp log_reason_string(_props), do: :ok
end
