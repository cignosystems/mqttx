defmodule MqttX.Transport.Handler do
  @moduledoc false

  # Shared MQTT protocol state machine for all transport adapters.
  # This is a pure functional module — no `use GenServer`, no framework dependency.
  # Each transport constructs a `send_fn` closure at connection time.

  alias MqttX.Packet.Buffer
  alias MqttX.Packet.Codec
  alias MqttX.Server.Cluster
  alias MqttX.Server.Router
  alias MqttX.Server.SessionExpiry
  alias MqttX.Server.SessionStore
  alias MqttX.Telemetry
  alias MqttX.Packet.ReasonCodes, as: RC
  import MqttX.Packet.ReasonCodes, only: [is_error_code: 1]

  require Logger

  # Default cap on a single MQTT packet (1 MiB). §3.1.2.11.4 allows the server
  # to advertise/enforce a maximum; without a default, an unauthenticated peer
  # can declare a ~256 MB remaining length and force unbounded buffering.
  @default_max_packet_size 1_048_576

  # Cap on distinct retained topics per listener — prevents an authorized
  # publisher from exhausting memory with unique retained topics.
  @default_max_retained 100_000

  # The cap on publishes queued behind a client's Receive Maximum window, and
  # on what MqttX.Server.deliver/3 queues for a session while it is away, is
  # transport_opts :max_outbound_queue — normalized by MqttX.Server.Delivery.

  # Default ceiling, in seconds, on how long a session outlives its connection
  # (transport_opts :max_session_expiry_interval). A v5 client asking for more
  # is told the shorter interval in CONNACK (§3.2.2.3.2); a 3.1.1 client with
  # CleanSession 0, whose session would otherwise never end, gets this long.
  @default_max_session_expiry 86_400

  # How long a CONNECT waits for the connection it is taking over (§3.1.4) to
  # stop writing session state before resuming from the store.
  @takeover_timeout 5_000

  # Process.send_after/3 cannot schedule further out than this (ms)
  @max_timer_ms 4_294_967_295

  # Reason Codes a SUBACK (§3.9.3), a PUBACK (§3.4.2.1) and a CONNACK
  # (§3.2.2.2) may carry. Handler-supplied codes outside these sets collapse
  # to 0x80 Unspecified error rather than putting an undefined code on the wire.
  @suback_reason_codes [0x80, 0x83, 0x87, 0x8F, 0x91, 0x97, 0x9E, 0xA1, 0xA2]
  @puback_reason_codes [0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99]
  @connack_reason_codes [0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8C] ++
                          [0x8F, 0x90, 0x95, 0x97, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9F]

  # Absolute ceiling on socket idleness, independent of the negotiated Keep
  # Alive. MQTT's keepalive is the primary liveness mechanism, but it does
  # not apply when the client negotiates `keep_alive: 0` (§3.1.2.10) — this
  # backstop reaps sockets that would otherwise be held open forever.
  @default_max_idle_timeout 900_000

  # ---------- Public API ----------

  @doc """
  Build initial protocol state. Returns `{:error, :rate_limited}` if rate limited.
  """
  def init(handler, handler_opts, retained_table, rate_limiter, send_fn) do
    init(handler, handler_opts, retained_table, rate_limiter, send_fn, SessionStore.new())
  end

  def init(handler, handler_opts, retained_table, rate_limiter, send_fn, sessions) do
    if rate_limiter do
      case MqttX.Server.RateLimiter.allow_connection?(rate_limiter) do
        :ok -> :ok
        {:error, :rate_limited} -> throw(:connection_rate_limited)
      end
    end

    transport_opts =
      if is_list(handler_opts), do: Keyword.get(handler_opts, :transport_opts, %{}), else: %{}

    state = %{
      send_fn: send_fn,
      buffer: <<>>,
      protocol_version: nil,
      client_id: nil,
      handler: handler,
      handler_state: handler.init(handler_opts),
      retained_table: retained_table,
      rate_limiter: rate_limiter,
      # The listener's Session State (§4.1) — see MqttX.Server.SessionStore.
      #   session_lifetime: seconds the session outlives this connection, from
      #     the Session Expiry Interval or CleanSession and the listener's
      #     :max_session_expiry_interval (0 = ends with it, 0xFFFFFFFF = never)
      #   persistent: session_lifetime > 0, so in-flight state is mirrored
      #   session_present: what the CONNACK said (§3.2.2.1.1)
      #   session_handed_over: a newer connection took the session (§3.1.4)
      #   session_finished: the end-of-connection bookkeeping has run
      sessions: sessions,
      session_lifetime: 0,
      persistent: false,
      session_present: false,
      session_handed_over: false,
      session_finished: false,
      max_session_expiry_interval:
        case Map.get(transport_opts, :max_session_expiry_interval, @default_max_session_expiry) do
          :infinity -> nil
          n when is_integer(n) and n >= 0 -> n
          _ -> @default_max_session_expiry
        end,
      will_message: nil,
      # True only once the client has ended the session itself with DISCONNECT
      # 0x00 — the one close that discards the Will (§3.1.2.5). Every close the
      # broker initiates (protocol error, a handler's {:disconnect, ...},
      # MqttX.Server.disconnect/3, session takeover) publishes it.
      graceful_disconnect: false,
      # handle_disconnect must fire exactly once per connection — several
      # transport stop paths run both an inline notification and terminate.
      disconnect_notified: false,
      connected: false,
      keep_alive: 0,
      keepalive_timer: nil,
      # Keepalive-independent idle ceiling (see @default_max_idle_timeout)
      max_idle_timeout:
        case Map.get(transport_opts, :max_idle_timeout, @default_max_idle_timeout) do
          :infinity -> nil
          ms when is_integer(ms) and ms > 0 -> ms
          _ -> @default_max_idle_timeout
        end,
      idle_timer: nil,
      session_expiry_interval: nil,
      # In-flight QoS 1/2 state (§4.3). Entries stay until the peer
      # acknowledges them or the connection ends: nothing is re-sent on a live
      # connection (§4.4, MQTT-4.4.0-1).
      #   pending_qos2_rx: packet_id => {packet, opts}, awaiting PUBREL
      #   pending_qos2_tx: packet_id => %{phase: :pubrec_pending | :pubrel_sent,
      #                                   packet: packet | nil}
      #   pending_qos1_tx: packet_id => packet, awaiting PUBACK
      pending_qos2_rx: %{},
      pending_qos2_tx: %{},
      pending_qos1_tx: %{},
      # QoS > 0 publishes waiting for Receive Maximum capacity (§3.3.4)
      outbound_queue: :queue.new(),
      # Filters this connection is subscribed to — needed for
      # retain_handling=1 ("send retained only if the subscription is new",
      # §3.8.3.1) and for capping retained delivery at the granted QoS
      subscribed_filters: MapSet.new(),
      # This connection's subscription index. Outbound publishes returned from
      # handle_info fan out through it so the per-subscription options
      # (granted QoS, no_local, retain_as_published, subscription_identifier)
      # are applied to each delivery.
      router: Router.new(),
      next_packet_id: 1,
      # Retained store cap (per listener; :infinity to disable)
      max_retained_messages:
        case Map.get(transport_opts, :max_retained_messages, @default_max_retained) do
          :infinity -> nil
          n when is_integer(n) and n > 0 -> n
          _ -> @default_max_retained
        end,
      # Topic aliases (MQTT 5.0)
      topic_alias_to_topic: %{},
      server_topic_alias_maximum: Map.get(transport_opts, :topic_alias_maximum, 100),
      client_topic_alias_maximum: 0,
      # Flow control
      server_receive_maximum: Map.get(transport_opts, :receive_maximum, 65535),
      client_receive_maximum: 65535,
      inflight_count: 0,
      # Max packet size — enforced on the *declared* remaining length before
      # buffering, so an unauthenticated peer cannot force large allocations.
      # Set `max_packet_size: :infinity` to disable (not recommended).
      server_max_packet_size:
        case Map.get(transport_opts, :max_packet_size, @default_max_packet_size) do
          :infinity -> nil
          nil -> @default_max_packet_size
          size when is_integer(size) and size > 0 -> size
        end,
      client_max_packet_size: nil,
      # Server keepalive override (MQTT 5.0) — must be positive integer or nil
      server_keep_alive:
        case Map.get(transport_opts, :server_keep_alive) do
          val when is_integer(val) and val > 0 -> val
          _ -> nil
        end,
      # Versions this server will accept — anything outside the list gets
      # CONNACK with Unacceptable Protocol Version (§3.2.2.2).
      supported_versions: Map.get(transport_opts, :supported_versions, [3, 4, 5]),
      handler_has_handle_connect4: function_exported?(handler, :handle_connect, 4),
      handler_has_handle_info: function_exported?(handler, :handle_info, 2),
      handler_has_handle_puback: function_exported?(handler, :handle_puback, 2),
      handler_has_handle_auth: function_exported?(handler, :handle_auth, 3),
      handler_has_handle_session_expired: function_exported?(handler, :handle_session_expired, 2),
      # Enhanced authentication (§4.12): the CONNECT's Authentication Method,
      # kept for the life of the connection — every AUTH and the successful
      # CONNACK must repeat it (MQTT-4.12.0-5) and a re-authentication must
      # name it again (MQTT-4.12.1-1) — and, while the exchange that precedes
      # CONNACK is running, what completing the CONNECT will need.
      auth_method: nil,
      pending_connect: nil,
      # Set when the CONNECT carried a zero-length Client Identifier and the
      # broker generated one (§3.1.3.1); advertised to v5 clients in CONNACK.
      assigned_client_id: nil,
      # QoS > 0 publishes waiting for Receive Maximum capacity are bounded;
      # past the bound they are dropped with a warning (:infinity disables).
      max_outbound_queue: MqttX.Server.Delivery.max_outbound_queue(transport_opts)
    }

    # A peer must complete CONNECT within a bounded window — otherwise an
    # unauthenticated socket (opened and left idle, or dribbling a partial
    # header) can be held forever; the keepalive timer only starts after a
    # successful CONNECT. Configurable via transport_opts :connect_timeout.
    case Map.get(transport_opts, :connect_timeout, 10_000) do
      :infinity -> :ok
      timeout_ms -> Process.send_after(self(), :mqtt_connect_timeout, timeout_ms)
    end

    # MqttX.Server.deliver/3, called from a handler callback, finds its
    # listener here
    Process.put(:mqttx_listener, %{
      sessions: sessions,
      retained_table: retained_table,
      max_outbound_queue: state.max_outbound_queue,
      listener: sessions.listener
    })

    {:ok, reset_idle_timer(state)}
  catch
    :connection_rate_limited -> {:error, :rate_limited}
  end

  @doc """
  Process incoming binary data (buffer accumulation + decode loop).
  """
  def handle_data(data, state) do
    # Any inbound bytes count as liveness for the idle ceiling — this is
    # deliberately independent of the MQTT keepalive timer, which does not
    # run when the client negotiated keep_alive: 0.
    state = reset_idle_timer(state)

    case Buffer.push(state.buffer, data) do
      {:more, buffer} ->
        # Mid-packet: its length is known and not all of it has arrived, so
        # there is nothing to decode. The read is kept without copying or
        # re-scanning what is already buffered (see MqttX.Packet.Buffer).
        {:ok, %{state | buffer: buffer}}

      {:ready, buffer} ->
        case process_buffer(buffer, state) do
          {:ok, new_state} ->
            {:ok, new_state}

          {:close, reason, new_state} ->
            Logger.debug("[MqttX.Transport] Closing connection: #{inspect(reason)}")
            {:close, reason, new_state}

          {:error, reason, new_state} ->
            Logger.warning("[MqttX.Transport] Error: #{inspect(reason)}")
            {:error, reason, new_state}
        end
    end
  end

  @doc """
  Transport connection closed.
  """
  def handle_close(state) do
    connected = Map.get(state, :connected, false)
    graceful = Map.get(state, :graceful_disconnect, false)

    if connected and not graceful do
      Telemetry.server_client_disconnect(%{client_id: state.client_id, reason: :closed})
    end

    state =
      if connected and not is_nil(Map.get(state, :will_message)) and not graceful do
        maybe_publish_will(state)
        %{state | will_message: nil}
      else
        state
      end

    if connected and not state.disconnect_notified and state.handler != nil do
      state.handler.handle_disconnect(:closed, state.handler_state)
    end

    state = if connected, do: end_connection_session(state), else: state

    {:shutdown, state}
  end

  @doc """
  Transport error.
  """
  def handle_error(reason, state) do
    Logger.warning("[MqttX.Transport] Connection error: #{inspect(reason)}")

    state =
      if state.connected and not is_nil(state.will_message) and not state.graceful_disconnect do
        maybe_publish_will(state)
        %{state | will_message: nil}
      else
        state
      end

    if state.connected and not state.disconnect_notified and state.handler != nil do
      state.handler.handle_disconnect({:error, reason}, state.handler_state)
    end

    state = if state.connected, do: end_connection_session(state), else: state

    {:shutdown, state}
  end

  @doc """
  Idle timeout.
  """
  def handle_timeout(state) do
    Logger.debug("[MqttX.Transport] Connection timeout")

    # An idle timeout is an abnormal disconnect: the will must be published
    # and session expiry started, exactly as on a socket close (§3.1.2.5).
    state =
      if state.connected and not is_nil(state.will_message) and not state.graceful_disconnect do
        maybe_publish_will(state)
        %{state | will_message: nil}
      else
        state
      end

    if state.connected and not state.disconnect_notified and state.handler != nil do
      state.handler.handle_disconnect(:timeout, state.handler_state)
    end

    state = if state.connected, do: end_connection_session(state), else: state

    {:close, state}
  end

  @doc """
  Out-of-band messages (:keepalive_timeout, {:server_disconnect, ...}, custom).
  """
  def handle_info(:keepalive_timeout, state) do
    # inspect/1, not raw interpolation: client_id is attacker-supplied and the
    # codec permits CR/LF and ANSI escapes, which would forge log records.
    Logger.debug("[MqttX.Transport] Keepalive timeout for #{inspect(state.client_id)}")

    state =
      if state.connected and not is_nil(state.will_message) do
        maybe_publish_will(state)
        # Clear the will so handle_close/terminate doesn't publish it a second
        # time (§3.1.2.5 — Will is delivered exactly once on abnormal close).
        %{state | will_message: nil}
      else
        state
      end

    state =
      if state.connected and not state.disconnect_notified and state.handler != nil do
        state.handler.handle_disconnect(:keepalive_timeout, state.handler_state)
        %{state | disconnect_notified: true}
      else
        state
      end

    state = if state.connected, do: end_connection_session(state), else: state

    {:stop, :normal, state}
  end

  def handle_info({:server_disconnect, reason_code, properties}, state) do
    send_disconnect(state, reason_code, properties)

    state =
      if state.connected and not state.disconnect_notified and state.handler != nil do
        state.handler.handle_disconnect({:server_disconnect, reason_code}, state.handler_state)
        %{state | disconnect_notified: true}
      else
        state
      end

    # A close we initiate is not a graceful one: the Will is published
    # (§3.1.2.5 — "the Server closes the Network Connection without first
    # receiving a DISCONNECT with Reason Code 0x00") and the session runs on to
    # its expiry. Session takeover (§3.1.4) is the exception on both counts:
    # the new connection owns the session now, so nothing of it expires, and a
    # delayed Will is cancelled by that connection (§3.1.3.2.2) — only an
    # immediate Will still goes out.
    state =
      if reason_code == RC.session_taken_over() do
        will = if will_delayed?(state), do: nil, else: state.will_message
        %{state | will_message: will, session_expiry_interval: nil, session_handed_over: true}
      else
        state
      end

    state = if state.connected, do: end_connection_session(state), else: state

    {:stop, :normal, state}
  end

  # Pre-CONNECT handshake deadline (armed in init/5): a socket that hasn't
  # completed CONNECT by now is closed instead of being held open forever.
  def handle_info(:mqtt_connect_timeout, %{connected: true} = state), do: {:noreply, state}

  def handle_info(:mqtt_connect_timeout, state) do
    Logger.debug("[MqttX.Transport] Closing connection: no CONNECT within the handshake window")
    {:stop, :normal, state}
  end

  # Keepalive-independent idle ceiling. Unlike :keepalive_timeout this fires
  # even when the client negotiated keep_alive: 0, so a peer cannot hold a
  # socket open indefinitely by simply staying silent.
  def handle_info(:mqtt_idle_timeout, state) do
    Logger.debug(
      "[MqttX.Transport] Idle timeout (#{state.max_idle_timeout}ms) for #{inspect(state.client_id)}"
    )

    abnormal_close(state, :idle_timeout)
  end

  # Exit signals from linked processes. The ThousandIsland transport traps
  # exits (to run its close callbacks), so there an exit from a process the
  # user's handler linked to — a Phoenix.PubSub or Registry partition (both
  # link to registrants), a Task — arrives as a message instead of killing the
  # connection as it does on the other transports. Give it the semantics a
  # non-trapping process would have: ignore :normal, otherwise close. It is
  # never passed to handle_info/2, whose contract is the application's own
  # messages; a handler without a catch-all clause used to crash on it.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning(
      "[MqttX.Transport] Linked process #{inspect(pid)} exited (#{inspect(reason)}) — " <>
        "closing connection #{inspect(state.client_id)}"
    )

    abnormal_close(state, {:linked_process_exit, reason})
  end

  # MqttX.Server.deliver/3 queued something for this session
  def handle_info(:mqttx_drain, %{connected: true} = state),
    do: {:noreply, drain_outbound_queue(state)}

  def handle_info(:mqttx_drain, state), do: {:noreply, state}

  # MqttX.Server.deliver/3 sending straight to a session that ends with this
  # connection — nothing to queue for, so no store round trip. The client id
  # is a guard against a message meant for a previous holder of the pid.
  def handle_info(
        {:mqttx_deliver, client_id, topic, payload, opts, queued_at},
        %{connected: true, client_id: client_id} = state
      ) do
    case age_message_expiry(opts, queued_at) do
      {:ok, opts} -> {:noreply, send_publish(state, topic, payload, opts)}
      :expired -> {:noreply, state}
    end
  end

  def handle_info({:mqttx_deliver, _, _, _, _, _}, state), do: {:noreply, state}

  # §3.1.4-3: a new connection for this client_id is taking the session over.
  # Same as {:server_disconnect, 0x8E, _} — DISCONNECT, only an immediate
  # Will — plus a reply once this process has stopped touching the session
  # state the new connection is about to read from the store.
  def handle_info({:session_takeover, new_pid}, state) do
    {:stop, :normal, state} =
      handle_info({:server_disconnect, RC.session_taken_over(), %{}}, state)

    send(new_pid, {:session_released, self()})
    {:stop, :normal, state}
  end

  # A reply from a connection we took over, arriving after the wait ended
  def handle_info({:session_released, _pid}, state), do: {:noreply, state}

  def handle_info(message, state) do
    if state.connected and state.handler_has_handle_info do
      case state.handler.handle_info(message, state.handler_state) do
        {:ok, new_handler_state} ->
          {:noreply, %{state | handler_state: new_handler_state}}

        {:publish, topic, payload, new_handler_state} ->
          new_state =
            route_outbound_publish(%{state | handler_state: new_handler_state}, topic, payload, %{
              qos: 0,
              retain: false
            })

          {:noreply, new_state}

        {:publish, topic, payload, opts, new_handler_state} ->
          state = %{state | handler_state: new_handler_state}

          case apply_outbound_codec(payload, opts) do
            {:ok, payload, opts} ->
              {:noreply, route_outbound_publish(state, topic, payload, opts)}

            {:error, reason} ->
              Logger.warning(
                "[MqttX.Transport] Dropping publish to #{inspect(topic)}: " <>
                  "#{inspect(opts[:codec])} failed to encode the payload: #{inspect(reason)}"
              )

              {:noreply, state}
          end

        {:disconnect, reason_code, new_handler_state} ->
          send_disconnect(state, reason_code, %{})
          state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

          {:stop, :normal,
           %{
             state
             | handler_state: new_handler_state,
               disconnect_notified: true
           }}

        {:disconnect, reason_code, properties, new_handler_state} ->
          send_disconnect(state, reason_code, properties)
          state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

          {:stop, :normal,
           %{
             state
             | handler_state: new_handler_state,
               disconnect_notified: true
           }}

        {:stop, _reason, new_handler_state} ->
          {:stop, :normal, %{state | handler_state: new_handler_state}}
      end
    else
      {:noreply, state}
    end
  end

  # ---------- Private functions ----------

  # An abnormal disconnect decided server-side (idle ceiling, linked-process
  # exit): publish the Will exactly once and notify the handler exactly once,
  # mirroring the keepalive-timeout path, then stop.
  defp abnormal_close(state, reason) do
    state =
      if state.connected and not is_nil(state.will_message) do
        maybe_publish_will(state)
        %{state | will_message: nil}
      else
        state
      end

    state =
      if state.connected and not state.disconnect_notified and state.handler != nil do
        state.handler.handle_disconnect(reason, state.handler_state)
        %{state | disconnect_notified: true}
      else
        state
      end

    state = if state.connected, do: end_connection_session(state), else: state

    {:stop, :normal, state}
  end

  # Process incoming data buffer
  defp process_buffer(buffer, state) do
    version = state.protocol_version || 4
    max_size = state.server_max_packet_size

    # Enforce the size limit on the *declared* remaining length as soon as the
    # fixed header is parseable — before the body is buffered — so a peer
    # cannot make us accumulate up to its declared size (§3.1.2.11.4).
    case max_size && Codec.declared_length(buffer) do
      {:ok, declared} when declared > max_size ->
        state = %{state | buffer: <<>>}

        cond do
          # Live connection: DISCONNECT 0x95; the Will publishes (§3.1.2.5)
          state.connected ->
            send_disconnect(state, RC.packet_too_large(), %{})
            {:close, :packet_too_large, state}

          # Mid enhanced-authentication exchange: no DISCONNECT may precede a
          # successful CONNACK (MQTT-3.14.0-1), so the CONNECT fails with 0x95
          match?(%{pending_connect: %{}}, state) ->
            reject_connect(state, RC.packet_too_large())

          # Before CONNECT there is nothing to answer with
          true ->
            {:close, :packet_too_large, state}
        end

      _ ->
        case Codec.decode(version, buffer) do
          {:ok, {packet, rest}} ->
            case handle_packet(packet, state) do
              {:ok, new_state} ->
                process_buffer(rest, %{reset_keepalive_timer(new_state) | buffer: rest})

              {:close, reason, new_state} ->
                {:close, reason, %{new_state | buffer: rest}}
            end

          {:error, :incomplete} ->
            # The declared length already passed the size check above (when
            # a limit is configured), so wait for exactly that many bytes
            {:ok, %{state | buffer: Buffer.stash(buffer)}}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  # A packet that is not AUTH while the enhanced authentication exchange is
  # running (the client may send nothing else before CONNACK, MQTT-4.12.0-2 on
  # its side) fails the CONNECT with 0x82 Protocol Error.
  defp handle_packet(%{type: type}, %{connected: false, pending_connect: %{}} = state)
       when type != :auth do
    reject_connect(state, RC.protocol_error())
  end

  # A packet other than CONNECT/AUTH before any CONNECT. There is nothing to
  # answer with — a DISCONNECT may only follow a successful CONNACK
  # (MQTT-3.14.0-1) — so the connection is simply closed (§4.13).
  defp handle_packet(%{type: type}, %{connected: false} = state)
       when type not in [:connect, :auth] do
    {:close, :protocol_error, state}
  end

  # §3.1.0-2: a second CONNECT on a live connection is a protocol error.
  # Processing it would re-run auth, send a duplicate CONNACK, and leak the
  # previous keepalive timer (which would later kill the session and fire
  # the will spuriously).
  defp handle_packet(%{type: :connect}, %{connected: true} = state) do
    send_disconnect(state, RC.protocol_error(), %{})
    {:close, :protocol_error, state}
  end

  # Handle CONNECT
  defp handle_packet(%{type: :connect} = packet, state) do
    protocol_version = packet.protocol_version

    # NOTE: cancelling this client_id's pending Will Delay / Session Expiry
    # happens only AFTER the handler authorizes the CONNECT (see
    # do_handle_connect_authorized/4) — doing it here would let an
    # unauthenticated peer suppress a real device's Will by merely claiming
    # its client_id.
    telemetry_meta = %{client_id: packet.client_id, protocol_version: protocol_version}
    start_time = System.monotonic_time()
    Telemetry.server_client_connect_start(telemetry_meta)

    if protocol_version not in state.supported_versions do
      # §3.2.2.2: reject with Unacceptable Protocol Version. v5 uses 0x84;
      # earlier versions use 0x01.
      reason_code =
        if protocol_version >= 5,
          do: RC.unsupported_protocol_version(),
          else: RC.v3_unacceptable_protocol_version()

      connack = %{
        type: :connack,
        session_present: false,
        reason_code: reason_code,
        properties: %{}
      }

      send_packet(state, connack, protocol_version)

      duration = System.monotonic_time() - start_time

      Telemetry.server_client_connect_exception(
        duration,
        Map.put(telemetry_meta, :reason_code, reason_code)
      )

      {:close, :unsupported_protocol_version, state}
    else
      # MQTT-3.1.3-7/-8 (v3.1.1): a zero-byte ClientID is only valid together
      # with CleanSession=1 — otherwise reject with 0x02 Identifier rejected.
      if protocol_version in [3, 4] and packet.client_id in [nil, ""] and
           not packet.clean_session do
        connack = %{
          type: :connack,
          session_present: false,
          reason_code: RC.v3_identifier_rejected(),
          properties: %{}
        }

        send_packet(state, connack, protocol_version)

        duration = System.monotonic_time() - start_time

        Telemetry.server_client_connect_exception(
          duration,
          Map.put(telemetry_meta, :reason_code, RC.v3_identifier_rejected())
        )

        {:close, :identifier_rejected, state}
      else
        do_handle_connect_authorized(packet, state, telemetry_meta, start_time)
      end
    end
  end

  # Handle PUBLISH
  defp handle_packet(%{type: :publish} = packet, state) do
    if state.rate_limiter && state.client_id do
      case MqttX.Server.RateLimiter.allow_message?(state.rate_limiter, state.client_id) do
        :ok ->
          :ok

        {:error, :rate_limited} ->
          throw({:message_rate_limited, packet, state})
      end
    end

    # Resolve topic alias (MQTT 5.0)
    case resolve_topic_alias(packet, state) do
      {:ok, resolved_topic, state} ->
        handle_publish_with_topic(packet, resolved_topic, state)

      {:error, :topic_alias_invalid, state} ->
        send_disconnect(state, RC.topic_alias_invalid(), %{})

        {:close, {:server_disconnect, RC.topic_alias_invalid()}, state}
    end
  catch
    {:message_rate_limited, rate_limited_packet, current_state} ->
      # Refuse the message, keep the session. 0x96 Message rate too high is a
      # DISCONNECT-only code (§2.4); the per-message code for an administrative
      # limit is 0x97 Quota exceeded (§3.4.2.1, §3.5.2.1).
      if rate_limited_packet.qos == 1 do
        puback = %{
          type: :puback,
          packet_id: rate_limited_packet.packet_id,
          reason_code: RC.quota_exceeded(),
          properties: %{}
        }

        send_packet(current_state, puback, current_state.protocol_version)
      end

      if rate_limited_packet.qos == 2 do
        pubrec = %{
          type: :pubrec,
          packet_id: rate_limited_packet.packet_id,
          reason_code: RC.quota_exceeded(),
          properties: %{}
        }

        send_packet(current_state, pubrec, current_state.protocol_version)
      end

      {:ok, current_state}
  end

  # Handle SUBSCRIBE
  defp handle_packet(%{type: :subscribe} = packet, state) do
    handler = state.handler

    topics = Enum.map(packet.topics, fn t -> t.topic end)
    Telemetry.server_subscribe(%{client_id: state.client_id, topics: topics})

    case handler.handle_subscribe(packet.topics, state.handler_state) do
      {:ok, granted_qos, new_handler_state} ->
        # A grant of 0..2 accepts the subscription at that QoS; a reason code
        # >= 0x80 rejects that topic (§3.9.3). Anything else is normalized to
        # 0x80 Unspecified error — previously it crashed the SUBACK encoder.
        # The SUBACK MUST carry exactly one code per requested filter
        # (§3.9.3): a short grant list is padded with 0x80 (those filters are
        # rejected, not silently ignored) and a long one is truncated.
        acks =
          granted_qos
          |> normalize_subscribe_grants(length(packet.topics), state)
          |> Enum.zip_with(packet.topics, fn
            # §3.8.4: the granted QoS may not exceed the requested one, and
            # the SUBACK must say what was actually granted
            {:ok, granted}, sub -> {:ok, min(granted, Map.get(sub, :qos, 0))}
            ack, _sub -> ack
          end)

        suback = %{
          type: :suback,
          packet_id: packet.packet_id,
          acks: acks,
          properties: %{}
        }

        send_packet(state, suback, state.protocol_version)

        # A rejected filter is not established: it gets no retained delivery
        # and is not added to the routing index. (A rejected RE-subscribe
        # leaves any existing subscription for that filter intact, matching
        # §3.8.4 — replacement applies only to accepted subscriptions.)
        subscription_identifier = Map.get(packet.properties || %{}, :subscription_identifier)

        # Retained delivery must honor the GRANTED QoS (not the requested
        # one) and retain_handling=1 semantics (only for new subscriptions).
        enriched_topics =
          packet.topics
          |> Enum.zip(acks)
          |> Enum.flat_map(fn
            {sub, {:ok, granted}} ->
              [
                sub
                |> Map.put(:qos, min(Map.get(sub, :qos, 0), granted))
                |> Map.put(
                  :already_subscribed,
                  MapSet.member?(state.subscribed_filters, filter_key(sub))
                )
                |> Map.put(:subscription_identifier, subscription_identifier)
              ]

            {_sub, {:error, _code}} ->
              []
          end)

        router =
          Enum.reduce(enriched_topics, state.router, fn sub, router ->
            opts = [
              qos: sub.qos,
              no_local: Map.get(sub, :no_local, false),
              retain_as_published: Map.get(sub, :retain_as_published, false)
            ]

            opts =
              if subscription_identifier,
                do: opts ++ [subscription_identifier: subscription_identifier],
                else: opts

            # The flattened binary form (not the decoded segment list) so
            # Router.subscribe parses $share/... into a shared-group entry —
            # and so it matches the binary the UNSUBSCRIBE path removes
            filter = filter_key(sub)

            # The listener-wide index MqttX.Server.deliver/3 routes through,
            # and what a resumed session is rebuilt from (§4.1)
            SessionStore.subscribe(state.sessions, state.client_id, filter, Map.new(opts))
            Router.subscribe(router, filter, state.client_id, opts)
          end)

        state = deliver_retained_messages(%{state | router: router}, enriched_topics)

        subscribed =
          Enum.reduce(enriched_topics, state.subscribed_filters, fn sub, acc ->
            MapSet.put(acc, filter_key(sub))
          end)

        {:ok, %{state | handler_state: new_handler_state, subscribed_filters: subscribed}}

      {:disconnect, reason_code, new_handler_state} ->
        send_disconnect(state, reason_code, %{})
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{
           state
           | handler_state: new_handler_state,
             disconnect_notified: true
         }}

      {:disconnect, reason_code, properties, new_handler_state} ->
        send_disconnect(state, reason_code, properties)
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{
           state
           | handler_state: new_handler_state,
             disconnect_notified: true
         }}
    end
  end

  # Handle UNSUBSCRIBE
  defp handle_packet(%{type: :unsubscribe} = packet, state) do
    handler = state.handler

    case handler.handle_unsubscribe(packet.topics, state.handler_state) do
      {:ok, new_handler_state} ->
        # §3.11.3: 0x00 for a filter that was subscribed, 0x11 No subscription
        # existed otherwise (a pre-5 UNSUBACK carries no codes)
        acks =
          Enum.map(packet.topics, fn topic ->
            if MapSet.member?(state.subscribed_filters, filter_key(topic)),
              do: {:ok, :found},
              else: {:ok, :notfound}
          end)

        unsuback = %{
          type: :unsuback,
          packet_id: packet.packet_id,
          acks: acks,
          properties: %{}
        }

        send_packet(state, unsuback, state.protocol_version)

        subscribed =
          Enum.reduce(packet.topics, state.subscribed_filters, fn topic, acc ->
            MapSet.delete(acc, filter_key(topic))
          end)

        router =
          Enum.reduce(packet.topics, state.router, fn topic, router ->
            filter = filter_key(topic)
            SessionStore.unsubscribe(state.sessions, state.client_id, filter)
            Router.unsubscribe(router, filter, state.client_id)
          end)

        {:ok,
         %{
           state
           | handler_state: new_handler_state,
             subscribed_filters: subscribed,
             router: router
         }}

      {:disconnect, reason_code, new_handler_state} ->
        send_disconnect(state, reason_code, %{})
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{
           state
           | handler_state: new_handler_state,
             disconnect_notified: true
         }}

      {:disconnect, reason_code, properties, new_handler_state} ->
        send_disconnect(state, reason_code, properties)
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{
           state
           | handler_state: new_handler_state,
             disconnect_notified: true
         }}
    end
  end

  # Handle PINGREQ
  defp handle_packet(%{type: :pingreq}, state) do
    pingresp = %{type: :pingresp}
    send_packet(state, pingresp, state.protocol_version)
    {:ok, state}
  end

  # Handle DISCONNECT — §3.14.4: Will is published on reason 0x04
  # (Disconnect with Will Message); for any other reason (default 0x00 Normal),
  # the Will is silently discarded.
  defp handle_packet(%{type: :disconnect} = packet, state) do
    state = cancel_keepalive_timer(state)

    reason_code = Map.get(packet, :reason_code, 0)
    props = Map.get(packet, :properties, %{}) || %{}
    new_sei = Map.get(props, :session_expiry_interval)

    # §3.14.2.2.2: the client may revise its Session Expiry Interval on
    # DISCONNECT (commonly SEI=0: "delete my session now") — but only if it
    # set a non-zero SEI at CONNECT; 0 → non-zero is a Protocol Error.
    cond do
      is_integer(new_sei) and new_sei > 0 and (state.session_expiry_interval || 0) == 0 ->
        send_disconnect(state, RC.protocol_error(), %{})
        {:close, :protocol_error, state}

      true ->
        state =
          if new_sei do
            lifetime = session_lifetime(state, state.protocol_version, new_sei, false)
            %{state | session_expiry_interval: new_sei, session_lifetime: lifetime}
          else
            state
          end

        Telemetry.server_client_disconnect(%{client_id: state.client_id, reason: :normal})

        state =
          if reason_code == RC.disconnect_with_will_message() and not is_nil(state.will_message) do
            maybe_publish_will(state)
            %{state | will_message: nil}
          else
            state
          end

        state =
          if not state.disconnect_notified and state.handler != nil do
            state.handler.handle_disconnect(:normal, state.handler_state)
            %{state | disconnect_notified: true}
          else
            state
          end

        state = end_connection_session(state)

        {:close, :disconnect, %{state | graceful_disconnect: true}}
    end
  end

  # Handle PUBACK (for QoS 1 outgoing messages)
  defp handle_packet(%{type: :puback} = packet, state) do
    pending_qos1_tx = Map.delete(state.pending_qos1_tx, packet.packet_id)

    state =
      untrack_inflight(%{state | pending_qos1_tx: pending_qos1_tx}, {:tx1, packet.packet_id})

    state = drain_outbound_queue(state)

    if state.handler_has_handle_puback do
      case state.handler.handle_puback(packet.packet_id, state.handler_state) do
        {:ok, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state}}
      end
    else
      {:ok, state}
    end
  end

  # Handle PUBREC (client acknowledges receipt of outgoing QoS 2 PUBLISH)
  defp handle_packet(%{type: :pubrec} = packet, state) do
    reason_code = Map.get(packet, :reason_code, 0)

    case Map.get(state.pending_qos2_tx, packet.packet_id) do
      nil ->
        # Unknown packet id: answer PUBREL 0x92 (v5, §4.3.3) so a conformant
        # peer can complete its half of the flow instead of waiting forever.
        if (state.protocol_version || 4) >= 5 do
          pubrel = %{
            type: :pubrel,
            packet_id: packet.packet_id,
            reason_code: RC.packet_identifier_not_found(),
            properties: %{}
          }

          send_packet(state, pubrel, state.protocol_version)
        end

        {:ok, state}

      %{phase: :pubrel_sent} ->
        # §4.3.3 figure 4.4: a duplicate PUBREC after PUBREL has already been
        # sent must NOT trigger another PUBREL. Wait for the original PUBCOMP.
        {:ok, state}

      _entry when is_error_code(reason_code) ->
        # §4.3.3: an error PUBREC aborts the flow — discard the message and
        # do NOT send PUBREL.
        Logger.debug(
          "[MqttX.Transport] QoS 2 PUBLISH #{packet.packet_id} rejected by client: 0x#{Integer.to_string(reason_code, 16)}"
        )

        pending = Map.delete(state.pending_qos2_tx, packet.packet_id)
        state = untrack_inflight(%{state | pending_qos2_tx: pending}, {:tx2, packet.packet_id})
        {:ok, drain_outbound_queue(state)}

      _entry ->
        # Send PUBREL to complete the QoS 2 handshake
        pubrel = %{type: :pubrel, packet_id: packet.packet_id}
        send_packet(state, pubrel, state.protocol_version)

        entry = %{phase: :pubrel_sent, packet: nil}
        pending = Map.put(state.pending_qos2_tx, packet.packet_id, entry)

        {:ok,
         track_inflight(%{state | pending_qos2_tx: pending}, {:tx2, packet.packet_id}, entry)}
    end
  end

  # Handle PUBREL (client releases QoS 2 message for delivery)
  defp handle_packet(%{type: :pubrel} = packet, state) do
    case Map.pop(state.pending_qos2_rx, packet.packet_id) do
      {nil, _} ->
        # Unknown packet_id — send PUBCOMP with 0x92 (Packet Identifier not found) per spec 4.3.3
        pubcomp = %{
          type: :pubcomp,
          packet_id: packet.packet_id,
          reason_code: RC.packet_identifier_not_found(),
          properties: %{}
        }

        send_packet(state, pubcomp, state.protocol_version)
        {:ok, state}

      {{stored_packet, opts}, remaining} ->
        # Now deliver the message to the handler
        handler = state.handler

        case handler.handle_publish(
               stored_packet.topic,
               stored_packet.payload,
               opts,
               state.handler_state
             ) do
          {:ok, new_handler_state} ->
            # QoS 2 retained messages are stored at delivery (PUBREL), after
            # the handler accepted the publish
            if stored_packet.retain do
              store_retained_message(stored_packet, state)
            end

            pubcomp = %{type: :pubcomp, packet_id: packet.packet_id}
            send_packet(state, pubcomp, state.protocol_version)

            {:ok,
             untrack_inflight(
               %{
                 state
                 | handler_state: new_handler_state,
                   pending_qos2_rx: remaining,
                   inflight_count: max(state.inflight_count - 1, 0)
               },
               {:rx2, packet.packet_id}
             )}

          {:error, _reason, new_handler_state} ->
            pubcomp = %{type: :pubcomp, packet_id: packet.packet_id}
            send_packet(state, pubcomp, state.protocol_version)

            {:ok,
             untrack_inflight(
               %{
                 state
                 | handler_state: new_handler_state,
                   pending_qos2_rx: remaining,
                   inflight_count: max(state.inflight_count - 1, 0)
               },
               {:rx2, packet.packet_id}
             )}

          {:disconnect, reason_code, new_handler_state} ->
            send_disconnect(state, reason_code, %{})
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{
               state
               | handler_state: new_handler_state,
                 disconnect_notified: true
             }}

          {:disconnect, reason_code, properties, new_handler_state} ->
            send_disconnect(state, reason_code, properties)
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{
               state
               | handler_state: new_handler_state,
                 disconnect_notified: true
             }}
        end
    end
  end

  # Handle PUBCOMP (client confirms QoS 2 outgoing flow complete)
  defp handle_packet(%{type: :pubcomp} = packet, state) do
    pending = Map.delete(state.pending_qos2_tx, packet.packet_id)
    state = untrack_inflight(%{state | pending_qos2_tx: pending}, {:tx2, packet.packet_id})
    state = drain_outbound_queue(state)

    if state.handler_has_handle_puback do
      case state.handler.handle_puback(packet.packet_id, state.handler_state) do
        {:ok, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state}}
      end
    else
      {:ok, state}
    end
  end

  # Handle AUTH (MQTT 5.0 enhanced authentication, §4.12). Valid only (a) inside
  # the exchange a CONNECT with an Authentication Method started — the CONNACK
  # is still outstanding — or (b) as re-authentication on a live connection.
  # Before any CONNECT there is not even a protocol version to answer in, and a
  # DISCONNECT may not precede CONNACK (MQTT-3.14.0-1): just close (§4.13).
  defp handle_packet(%{type: :auth}, %{connected: false, protocol_version: nil} = state) do
    {:close, :protocol_error, state}
  end

  # (a) Mid-handshake: the client's answer to our AUTH 0x18 challenge. It must
  # itself be 0x18 (MQTT-4.12.0-3) and repeat the CONNECT's method
  # (MQTT-4.12.0-5); anything else fails the CONNECT.
  defp handle_packet(%{type: :auth} = packet, %{connected: false, pending_connect: %{}} = state) do
    method = get_in(packet, [:properties, :authentication_method])

    cond do
      Map.get(packet, :reason_code, 0) != RC.continue_authentication() ->
        reject_connect(state, RC.protocol_error())

      method != state.auth_method ->
        reject_connect(state, RC.bad_authentication_method())

      true ->
        continue_enhanced_auth(state, get_in(packet, [:properties, :authentication_data]))
    end
  end

  # (b) Re-authentication (§4.12.1). The method must be the one the connection
  # was authenticated with (MQTT-4.12.1-1); a connection that did not use
  # enhanced authentication has none, and 0x8C covers both cases ("does not
  # match the authentication method currently in use").
  defp handle_packet(%{type: :auth} = packet, state) do
    method = get_in(packet, [:properties, :authentication_method])
    data = get_in(packet, [:properties, :authentication_data])

    cond do
      # Only 0x19 Re-authenticate and 0x18 Continue authentication come from a
      # client (§3.15.2.1), and the method is mandatory (§3.15.2.2.2)
      Map.get(packet, :reason_code, 0) not in [RC.continue_authentication(), RC.re_authenticate()] or
          is_nil(method) ->
        send_disconnect(state, RC.protocol_error(), %{})
        {:close, :protocol_error, state}

      is_nil(state.auth_method) or method != state.auth_method ->
        send_disconnect(state, RC.bad_authentication_method(), %{})
        {:close, :auth_failed, state}

      true ->
        case call_handle_auth(state, data) do
          {:ok, final_data, new_handler_state} ->
            # Success is signalled with AUTH 0x00 — a second CONNACK on a live
            # connection would be a protocol violation.
            send_packet(
              state,
              auth_packet(RC.success(), method, final_data),
              state.protocol_version
            )

            {:ok, %{state | handler_state: new_handler_state}}

          {:continue, challenge, new_handler_state} ->
            send_packet(
              state,
              auth_packet(RC.continue_authentication(), method, challenge),
              state.protocol_version
            )

            {:ok, %{state | handler_state: new_handler_state}}

          {:error, reason_code, new_handler_state} ->
            # MQTT-4.12.1-2: a failed re-authentication ends with DISCONNECT.
            state = %{state | handler_state: new_handler_state}
            send_disconnect(state, reason_code, %{})
            {:close, :auth_failed, state}
        end
    end
  end

  # Catch-all for other packets
  defp handle_packet(packet, state) do
    Logger.debug("[MqttX.Transport] Unhandled packet: #{inspect(packet.type)}")
    {:ok, state}
  end

  defp do_handle_connect_authorized(packet, state, telemetry_meta, start_time) do
    handler = state.handler
    protocol_version = packet.protocol_version
    connect_props = Map.get(packet, :properties, %{}) || %{}

    # §3.1.3.1: a zero-length Client Identifier asks the broker to assign one.
    # v5 clients learn it from the CONNACK (Assigned Client Identifier,
    # MQTT-3.1.3-7); pre-5 clients cannot, but the connection still needs a
    # real id for session takeover, timers and the handler.
    {packet, state} =
      if packet.client_id in [nil, ""] do
        assigned = generate_client_id()
        {%{packet | client_id: assigned}, %{state | assigned_client_id: assigned}}
      else
        {packet, state}
      end

    credentials = %{
      username: packet.username,
      password: packet.password
    }

    # MQTT 5.0 only — earlier versions decode with empty properties
    auth_method = Map.get(connect_props, :authentication_method)

    # §3.1.2.4: with Clean Start 0 an existing session is resumed. The handler
    # learns up front what that would bring back — from this node, another
    # node of the cluster or the durable backend, without touching it; the
    # restore itself happens in complete_connect/5, once the CONNECT is
    # authorized.
    stored = if packet.clean_session, do: nil, else: peek_session(state, packet.client_id)

    connect_info = %{
      protocol_version: protocol_version,
      keep_alive: Map.get(packet, :keep_alive, 0),
      authentication_method: auth_method,
      session_present: stored != nil,
      subscriptions: Enum.map(stored || [], &subscription_info/1)
    }

    connect_result =
      if state.handler_has_handle_connect4 do
        handler.handle_connect(packet.client_id, credentials, connect_info, state.handler_state)
      else
        handler.handle_connect(packet.client_id, credentials, state.handler_state)
      end

    case connect_result do
      {:ok, new_handler_state} when is_nil(auth_method) ->
        state = %{state | handler_state: new_handler_state}
        complete_connect(state, packet, telemetry_meta, start_time, nil)

      {:ok, new_handler_state} ->
        # §4.12 enhanced authentication: handle_auth/3 now drives an exchange
        # of AUTH packets and the CONNACK waits for it. The protocol version is
        # fixed from here so those packets decode as v5; `connected` stays
        # false, so a stalled exchange still meets the CONNECT deadline and a
        # drop before CONNACK fires neither the Will nor handle_disconnect.
        state = %{
          state
          | handler_state: new_handler_state,
            protocol_version: protocol_version,
            auth_method: auth_method,
            pending_connect: %{
              packet: packet,
              telemetry_meta: telemetry_meta,
              start_time: start_time
            }
        }

        continue_enhanced_auth(state, Map.get(connect_props, :authentication_data))

      {:error, reason_code, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        fail_connect(state, protocol_version, reason_code, telemetry_meta, start_time)
    end
  end

  # Authorization is complete — by handle_connect alone or after the enhanced
  # authentication exchange — so answer CONNACK and bring the session up.
  # Everything here is gated on that: an unauthenticated peer must not be able
  # to affect another client's session state by claiming its client_id.
  defp complete_connect(state, packet, telemetry_meta, start_time, final_auth_data) do
    protocol_version = packet.protocol_version
    connect_props = Map.get(packet, :properties, %{}) || %{}

    duration = System.monotonic_time() - start_time
    Telemetry.server_client_connect_stop(duration, telemetry_meta)

    # §3.1.3.2.2: a fresh CONNECT cancels any in-flight Will Delay for this
    # client_id from the previous abnormal disconnect; §3.1.2.11.2: it also
    # cancels a pending session expiry (the session resumed in time).
    if packet.client_id not in [nil, ""] do
      scope = timer_scope(state, packet.client_id)
      MqttX.Server.WillDelay.cancel(scope)
      MqttX.Server.SessionExpiry.cancel(scope)
    end

    # §3.1.4-3: a CONNECT with a client_id already in use takes over the
    # session — the existing connection is disconnected (0x8E), and this one
    # waits for it to let go before reading what it left in the store. The
    # other nodes of the cluster do the same for their connections and
    # timers, and hand over (or discard) a session they hold.
    take_over_existing_sessions(packet.client_id, state)
    claim_session(state, packet)

    # §3.1.2.4 Clean Start and §3.1.2.11 Session Expiry Interval: whether an
    # existing session is resumed, and how long this one outlives the
    # connection. The store knows the session from here on.
    requested_sei = Map.get(connect_props, :session_expiry_interval)
    lifetime = session_lifetime(state, protocol_version, requested_sei, packet.clean_session)
    resumed = begin_session(state, packet, protocol_version, lifetime)

    # MQTT-4.12.0-5: a successful CONNACK repeats the Authentication Method
    # (and may carry the mechanism's final data); MQTT-4.12.0-6: never
    # otherwise.
    connack_props =
      put_auth_properties(
        build_connack_properties(protocol_version, state),
        state.auth_method,
        final_auth_data
      )

    connack_props =
      if protocol_version >= 5 and state.assigned_client_id,
        do: Map.put(connack_props, :assigned_client_identifier, state.assigned_client_id),
        else: connack_props

    # §3.2.2.3.2: a server keeping the session for less than the client asked
    # says so, and the client must use that value
    connack_props =
      if protocol_version >= 5 and lifetime != (requested_sei || 0),
        do: Map.put(connack_props, :session_expiry_interval, lifetime),
        else: connack_props

    connack = %{
      type: :connack,
      # MQTT-3.2.2-2/-3: set only when Clean Start was 0 and a session existed
      session_present: resumed != nil,
      reason_code: 0,
      properties: connack_props
    }

    send_packet(state, connack, protocol_version)

    keep_alive = Map.get(packet, :keep_alive, 0) || 0

    # If server overrides keepalive (MQTT 5.0), use that for the timer
    keep_alive =
      if state.server_keep_alive && protocol_version >= 5 do
        state.server_keep_alive
      else
        keep_alive
      end

    new_state = %{
      state
      | protocol_version: protocol_version,
        client_id: packet.client_id,
        will_message: extract_will_message(packet),
        connected: true,
        pending_connect: nil,
        keep_alive: keep_alive,
        session_expiry_interval: requested_sei,
        session_lifetime: lifetime,
        persistent: lifetime > 0,
        session_present: resumed != nil,
        client_topic_alias_maximum: Map.get(connect_props, :topic_alias_maximum, 0),
        client_receive_maximum: Map.get(connect_props, :receive_maximum, 65535),
        client_max_packet_size: Map.get(connect_props, :maximum_packet_size)
    }

    register_session(packet.client_id, state)

    # After CONNACK (MQTT-3.2.0-1): re-send what the resumed session had in
    # flight — the one case re-sending is allowed (MQTT-4.4.0-1) — then what
    # was delivered to it while it was away
    new_state =
      new_state
      |> start_keepalive_timer()
      |> restore_session(resumed)
      |> drain_outbound_queue()

    {:ok, new_state}
  end

  # CONNACK with an error Reason Code; the connection then closes
  # (MQTT-3.2.2-7).
  defp fail_connect(state, protocol_version, reason_code, telemetry_meta, start_time) do
    duration = System.monotonic_time() - start_time

    Telemetry.server_client_connect_exception(
      duration,
      Map.put(telemetry_meta, :reason_code, reason_code)
    )

    connack = %{
      type: :connack,
      session_present: false,
      reason_code: connack_reason_code(protocol_version, reason_code),
      properties: %{}
    }

    send_packet(state, connack, protocol_version)
    {:close, :auth_failed, %{state | pending_connect: nil}}
  end

  # A handler may refuse a CONNECT with any MQTT 5.0 Reason Code. A pre-5
  # CONNACK only has return codes 1..5 (3.1.1 §3.2.2.3), so v5 codes map to
  # the nearest one; a v5 CONNACK may only carry a CONNACK code (§3.2.2.2), so
  # anything else becomes 0x80.
  defp connack_reason_code(version, code) when version < 5 do
    cond do
      code in 1..5 -> code
      code == RC.unsupported_protocol_version() -> RC.v3_unacceptable_protocol_version()
      code == 0x85 -> RC.v3_identifier_rejected()
      # Server unavailable / busy / use another server / server moved → 3
      code in [0x88, 0x89, 0x9C, 0x9D] -> 0x03
      # Bad user name or password → 4
      code == 0x86 -> 0x04
      # Not authorized (and everything else) → 5
      true -> 0x05
    end
  end

  defp connack_reason_code(_version, code) when code in @connack_reason_codes, do: code
  defp connack_reason_code(_version, _code), do: RC.unspecified_error()

  # fail_connect/5 for a CONNECT whose enhanced authentication exchange is
  # under way.
  defp reject_connect(%{pending_connect: pending} = state, reason_code) do
    fail_connect(
      state,
      state.protocol_version,
      reason_code,
      pending.telemetry_meta,
      pending.start_time
    )
  end

  # One step of the enhanced authentication exchange that precedes CONNACK.
  # `data` is the client's Authentication Data — from the CONNECT first, then
  # from each AUTH 0x18. The handler finishes with {:ok, ...} → CONNACK 0x00,
  # carries on with {:continue, ...} → AUTH 0x18 (MQTT-4.12.0-2), or fails it
  # with {:error, ...} → CONNACK with that Reason Code and the connection
  # closes (MQTT-4.12.0-1, §4.13).
  defp continue_enhanced_auth(%{pending_connect: pending} = state, data) do
    case call_handle_auth(state, data) do
      {:ok, final_data, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}

        complete_connect(
          state,
          pending.packet,
          pending.telemetry_meta,
          pending.start_time,
          final_data
        )

      {:continue, challenge, new_handler_state} ->
        send_packet(
          state,
          auth_packet(RC.continue_authentication(), state.auth_method, challenge),
          state.protocol_version
        )

        {:ok, %{state | handler_state: new_handler_state}}

      {:error, reason_code, new_handler_state} ->
        reject_connect(%{state | handler_state: new_handler_state}, reason_code)
    end
  end

  # handle_auth/3, normalized to {:ok, final_data | nil, hs} | {:continue, data,
  # hs} | {:error, reason_code, hs}. A handler written against the behaviour by
  # hand, without handle_auth/3, does not support enhanced authentication: 0x8C
  # Bad authentication method (MQTT-4.12.0-1).
  defp call_handle_auth(%{handler_has_handle_auth: false} = state, _data) do
    {:error, RC.bad_authentication_method(), state.handler_state}
  end

  defp call_handle_auth(state, data) do
    case state.handler.handle_auth(state.auth_method, data, state.handler_state) do
      {:ok, new_handler_state} -> {:ok, nil, new_handler_state}
      {:ok, _final_data, _new_handler_state} = ok -> ok
      {:continue, _challenge, _new_handler_state} = continue -> continue
      {:error, _reason_code, _new_handler_state} = error -> error
    end
  end

  defp auth_packet(reason_code, method, data) do
    %{type: :auth, reason_code: reason_code, properties: put_auth_properties(%{}, method, data)}
  end

  defp put_auth_properties(props, nil, _data), do: props
  defp put_auth_properties(props, method, nil), do: Map.put(props, :authentication_method, method)

  defp put_auth_properties(props, method, data) do
    props
    |> Map.put(:authentication_method, method)
    |> Map.put(:authentication_data, data)
  end

  # Process PUBLISH after topic alias resolution
  defp handle_publish_with_topic(packet, resolved_topic, state) do
    if Map.has_key?(packet.properties || %{}, :subscription_identifier) do
      # MQTT-3.3.4-6: a Subscription Identifier is set by the Server; one
      # arriving in a client PUBLISH is a Protocol Error
      send_disconnect(state, RC.protocol_error(), %{})
      {:close, :protocol_error, state}
    else
      do_handle_publish_with_topic(%{packet | topic: resolved_topic}, state)
    end
  end

  defp do_handle_publish_with_topic(packet, state) do
    handler = state.handler
    payload_size = byte_size(packet.payload || <<>>)

    Telemetry.server_publish(payload_size, %{
      client_id: state.client_id,
      topic: packet.topic,
      qos: packet.qos
    })

    opts = %{
      qos: packet.qos,
      retain: packet.retain,
      dup: packet.dup,
      packet_id: packet.packet_id,
      properties: packet.properties
    }

    cond do
      # §3.3.4 / §4.9: a client with more QoS > 0 PUBLISH packets in flight
      # than the Receive Maximum we advertised is a Protocol Error, answered
      # with DISCONNECT 0x93 (Receive Maximum exceeded) and the connection
      # closed. 0x93 is not a PUBACK/PUBREC code, so there is no per-message
      # variant.
      packet.qos > 0 and state.inflight_count >= state.server_receive_maximum ->
        send_disconnect(state, RC.receive_maximum_exceeded(), %{})
        {:close, {:server_disconnect, RC.receive_maximum_exceeded()}, state}

      packet.qos == 2 ->
        # DUP handling: if packet_id already pending, re-send PUBREC without re-storing
        if Map.has_key?(state.pending_qos2_rx, packet.packet_id) do
          pubrec = %{type: :pubrec, packet_id: packet.packet_id}
          send_packet(state, pubrec, state.protocol_version)
          {:ok, state}
        else
          pubrec = %{type: :pubrec, packet_id: packet.packet_id}
          send_packet(state, pubrec, state.protocol_version)

          pending = Map.put(state.pending_qos2_rx, packet.packet_id, {packet, opts})
          state = %{state | pending_qos2_rx: pending, inflight_count: state.inflight_count + 1}
          {:ok, track_inflight(state, {:rx2, packet.packet_id}, {packet, opts})}
        end

      true ->
        case handler.handle_publish(packet.topic, packet.payload, opts, state.handler_state) do
          {:ok, new_handler_state} ->
            # Store retained only after the handler accepted the publish, so
            # an unauthorized publisher cannot write to the retained store.
            if packet.retain do
              store_retained_message(packet, state)
            end

            if packet.qos == 1 do
              puback = %{type: :puback, packet_id: packet.packet_id}
              send_packet(state, puback, state.protocol_version)
            end

            {:ok, %{state | handler_state: new_handler_state}}

          {:error, reason, new_handler_state} ->
            # Refused, but still acknowledged (MQTT-3.3.4-1, MQTT-4.3.2-4):
            # without a PUBACK the publisher keeps the Packet Identifier in
            # flight forever and its send window shrinks to nothing. v5 carries
            # the refusal in the Reason Code; a pre-5 PUBACK has none. (QoS 2
            # is refused the same way at PUBREL, with PUBCOMP.)
            if packet.qos == 1 do
              puback = %{
                type: :puback,
                packet_id: packet.packet_id,
                reason_code: publish_refusal_code(reason),
                properties: %{}
              }

              send_packet(state, puback, state.protocol_version)
            end

            {:ok, %{state | handler_state: new_handler_state}}

          {:disconnect, reason_code, new_handler_state} ->
            send_disconnect(state, reason_code, %{})
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{
               state
               | handler_state: new_handler_state,
                 disconnect_notified: true
             }}

          {:disconnect, reason_code, properties, new_handler_state} ->
            send_disconnect(state, reason_code, properties)
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{
               state
               | handler_state: new_handler_state,
                 disconnect_notified: true
             }}
        end
    end
  end

  # §3.1.4-3 session takeover: connections register under
  # {retained_table, client_id} (the retained table identifies the listener,
  # so two brokers in one VM don't take over each other's clients). The
  # registry auto-deregisters on process exit.
  defp take_over_existing_sessions(client_id, state) when is_binary(client_id) do
    key = {state.retained_table, client_id}

    for {pid, _} <- Registry.lookup(MqttX.Server.ConnectionRegistry, key), pid != self() do
      Logger.info("[MqttX.Transport] Session takeover for #{inspect(client_id)}")
      ref = Process.monitor(pid)
      send(pid, {:session_takeover, self()})

      # The session is resumed from the store, so the old connection must have
      # stopped writing to it first: wait for its word or its exit, but no
      # longer than the handover deadline
      receive do
        {:session_released, ^pid} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @takeover_timeout -> Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end

  defp take_over_existing_sessions(_client_id, _state), do: :ok

  # Scope per-client timers to this listener, matching how session takeover
  # scopes its registry key.
  defp timer_scope(state, client_id), do: {state.retained_table, client_id}

  defp register_session(client_id, state) when is_binary(client_id) and client_id != "" do
    Registry.register(MqttX.Server.ConnectionRegistry, {state.retained_table, client_id}, nil)
    :ok
  end

  defp register_session(_client_id, _state), do: :ok

  defp generate_client_id do
    "mqttx-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp will_delayed?(%{will_message: %{delay_interval: delay}}) when delay > 0, do: true
  defp will_delayed?(_state), do: false

  # Map a handle_publish {:error, reason, _} to a PUBACK Reason Code
  # (§3.4.2.1): an integer that is itself a valid PUBACK code passes through,
  # the common atoms map to the nearest code, anything else is 0x80.
  defp publish_refusal_code(code) when code in @puback_reason_codes, do: code

  defp publish_refusal_code(reason) when reason in [:unauthorized, :not_authorized, :forbidden],
    do: RC.not_authorized()

  defp publish_refusal_code(:quota_exceeded), do: RC.quota_exceeded()
  defp publish_refusal_code(:topic_name_invalid), do: RC.topic_name_invalid()
  defp publish_refusal_code(:payload_format_invalid), do: RC.payload_format_invalid()
  defp publish_refusal_code(_reason), do: RC.unspecified_error()

  # Next outbound Packet Identifier not held by an in-flight QoS 1/2 publish
  defp next_free_packet_id(state, candidate, tries) when tries < 65535 do
    if Map.has_key?(state.pending_qos1_tx, candidate) or
         Map.has_key?(state.pending_qos2_tx, candidate) do
      next = if candidate >= 65535, do: 1, else: candidate + 1
      next_free_packet_id(state, next, tries + 1)
    else
      candidate
    end
  end

  defp next_free_packet_id(_state, candidate, _tries), do: candidate

  # MQTT-3.3.2-6: a forwarded message's Message Expiry Interval is the original
  # minus the time it spent waiting here; one that expired while queued is
  # dropped.
  defp age_message_expiry(opts, queued_at) do
    props = Map.get(opts, :properties) || %{}

    case Map.get(props, :message_expiry_interval) do
      nil ->
        {:ok, opts}

      interval ->
        waited = div(System.monotonic_time(:millisecond) - queued_at, 1000)

        if waited >= interval do
          :expired
        else
          {:ok, Map.put(opts, :properties, %{props | message_expiry_interval: interval - waited})}
        end
    end
  end

  # Send packet helper — uses send_fn closure
  defp send_packet(state, packet, version) do
    case Codec.encode_iodata(version || 4, packet) do
      {:ok, data} ->
        state.send_fn.(data)

      {:error, reason} ->
        Logger.warning("[MqttX.Transport] Failed to encode packet: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Send DISCONNECT packet to client (MQTT 5.0 only)
  defp send_disconnect(state, reason_code, properties) do
    if (state.protocol_version || 4) >= 5 do
      packet = %{
        type: :disconnect,
        reason_code: reason_code,
        # MQTT-3.14.2-2: a Server DISCONNECT never carries Session Expiry Interval
        properties: Map.delete(properties || %{}, :session_expiry_interval)
      }

      send_packet(state, packet, state.protocol_version)
    end
  end

  # Normalize a handle_subscribe grant list into SUBACK acks — exactly one
  # per requested filter. 0..2 accepts at that QoS; an error reason code
  # (§2.4, via is_error_code/1) rejects; anything else becomes 0x80. For
  # pre-5 clients the only failure return code is 0x80 (v3.1.1 §3.9.3), so
  # v5-only codes are collapsed to it on the wire.
  defp normalize_subscribe_grants(granted_qos, topic_count, state) do
    if length(granted_qos) != topic_count do
      Logger.warning(
        "[MqttX.Transport] handle_subscribe returned #{length(granted_qos)} grants " <>
          "for #{topic_count} filters (client #{inspect(state.client_id)}) — " <>
          "missing grants are rejected with 0x80"
      )
    end

    granted_qos
    |> Enum.concat(Stream.duplicate(RC.unspecified_error(), topic_count))
    |> Enum.take(topic_count)
    |> Enum.map(fn
      qos when qos in [0, 1, 2] ->
        {:ok, qos}

      code when is_integer(code) and is_error_code(code) and code <= 0xFF ->
        # Only SUBACK Reason Codes go on the wire (§3.9.3); other v5 codes
        # collapse to 0x80, as every code does for pre-5 clients
        if state.protocol_version == 5 and code in @suback_reason_codes,
          do: {:error, code},
          else: {:error, RC.unspecified_error()}

      _ ->
        {:error, RC.unspecified_error()}
    end)
  end

  # A handle_info publish tuple may name a MqttX.Payload codec in opts: the
  # payload is then a term to encode with it, and the codec's metadata
  # (payload format indicator, content type) is merged under any explicit
  # properties — the same contract as MqttX.Client.publish/4's :codec.
  defp apply_outbound_codec(payload, %{codec: codec} = opts) when not is_nil(codec) do
    with {:ok, binary, properties} <-
           MqttX.Payload.encode_with(codec, payload, Map.get(opts, :properties, %{})) do
      {:ok, binary, opts |> Map.delete(:codec) |> Map.put(:properties, properties)}
    end
  end

  defp apply_outbound_codec(payload, opts), do: {:ok, payload, opts}

  # Fan an application-initiated publish (a handle_info return value) out
  # through this connection's subscription index, applying each matching
  # subscription's options: QoS capped at the granted QoS (§3.8.4), the
  # retain flag forwarded only when the subscription set Retain As Published
  # (§3.3.1.3), no_local suppression against `opts[:publisher]` (§3.8.3.1),
  # and Subscription Identifiers attached (§3.3.4).
  #
  # A publish matching no subscription is sent as-is — the historical
  # contract, kept for brokers that make delivery decisions themselves.
  defp route_outbound_publish(state, topic, payload, opts) do
    publisher = Map.get(opts, :publisher)

    # Topic Alias is per-connection state the broker never assigns
    # (MQTT-3.1.2-26), and Subscription Identifiers belong to this client's
    # own subscriptions (§3.3.4) — an application relaying another
    # connection's properties must not leak either
    opts =
      opts
      |> Map.delete(:publisher)
      |> Map.update(:properties, %{}, fn props ->
        Map.drop(props || %{}, [:topic_alias, :subscription_identifier])
      end)

    case Router.match(state.router, topic, publisher) do
      [] ->
        if publisher != nil and Router.match(state.router, topic) != [] do
          # Every matching subscription was no_local with respect to the
          # publisher — suppress rather than fall back to a direct send.
          state
        else
          send_publish(state, topic, payload, opts)
        end

      matches ->
        # At most one entry for normal subscriptions (Router collapses per
        # client), plus one per matching shared group.
        Enum.reduce(matches, state, fn {_client, sub_opts}, st ->
          qos = min(Map.get(opts, :qos, 0), Map.get(sub_opts, :qos, 0))

          # `&&`, not `and`: the codec accepts any truthy retain (retain: 1),
          # and the no-match fallback tolerates it, so this path must too
          retain =
            !!(Map.get(opts, :retain, false) && Map.get(sub_opts, :retain_as_published, false))

          properties = Map.get(opts, :properties, %{})

          properties =
            case List.wrap(Map.get(sub_opts, :subscription_identifier)) do
              [] -> properties
              [id] -> Map.put(properties, :subscription_identifier, id)
              ids -> Map.put(properties, :subscription_identifier, ids)
            end

          send_publish(st, topic, payload, %{qos: qos, retain: retain, properties: properties})
        end)
    end
  end

  # Send PUBLISH packet to client. QoS > 0 sends are gated on the client's
  # advertised Receive Maximum (§3.3.4): excess messages queue and drain as
  # acks free capacity, instead of flooding constrained clients.
  defp send_publish(state, topic, payload, opts) do
    qos = Map.get(opts, :qos, 0)

    if qos > 0 and inflight_tx_total(state) >= state.client_receive_maximum do
      cap = state.max_outbound_queue

      if cap && :queue.len(state.outbound_queue) >= cap do
        Logger.warning(
          "[MqttX.Transport] Outbound queue full (#{cap}) — dropping QoS #{qos} publish to #{inspect(state.client_id)}"
        )

        state
      else
        # Remember when it was queued so Message Expiry keeps counting (§3.3.2.3.3)
        entry = {topic, payload, opts, System.monotonic_time(:millisecond)}
        %{state | outbound_queue: :queue.in(entry, state.outbound_queue)}
      end
    else
      do_send_publish(state, topic, payload, opts)
    end
  end

  defp inflight_tx_total(state) do
    map_size(state.pending_qos1_tx) + map_size(state.pending_qos2_tx)
  end

  # Send queued publishes as long as the Receive Maximum window has room.
  defp drain_outbound_queue(state) do
    if inflight_tx_total(state) < state.client_receive_maximum do
      case :queue.out(state.outbound_queue) do
        {{:value, {topic, payload, opts, queued_at}}, rest} ->
          state = %{state | outbound_queue: rest}

          state =
            case age_message_expiry(opts, queued_at) do
              {:ok, opts} -> do_send_publish(state, topic, payload, opts)
              :expired -> state
            end

          drain_outbound_queue(state)

        {:empty, _} ->
          drain_session_queue(state)
      end
    else
      state
    end
  end

  # What MqttX.Server.deliver/3 queued for this session — while it was away,
  # or a moment ago with a :mqttx_drain poke — in arrival order, for as long
  # as the Receive Maximum window has room.
  defp drain_session_queue(state) do
    if inflight_tx_total(state) < state.client_receive_maximum do
      case SessionStore.dequeue(state.sessions, state.client_id) do
        {:ok, {topic, payload, opts, queued_at}} ->
          state =
            case age_message_expiry(opts, queued_at) do
              {:ok, opts} -> do_send_publish(state, topic, payload, opts)
              :expired -> state
            end

          drain_session_queue(state)

        :empty ->
          state
      end
    else
      state
    end
  end

  defp do_send_publish(state, topic, payload, opts) do
    qos = Map.get(opts, :qos, 0)

    {packet_id, state} =
      if qos > 0 do
        # MQTT-2.2.1-3/-4: never reuse an identifier that is still in flight.
        # The window is bounded by the client's Receive Maximum (≤ 65535), so
        # a free id always exists once send_publish let the message through.
        id = next_free_packet_id(state, state.next_packet_id, 0)
        next = if id >= 65535, do: 1, else: id + 1
        {id, %{state | next_packet_id: next}}
      else
        {nil, state}
      end

    packet = %{
      type: :publish,
      topic: topic,
      payload: payload,
      qos: qos,
      retain: Map.get(opts, :retain, false),
      dup: false,
      packet_id: packet_id,
      properties: Map.get(opts, :properties, %{})
    }

    # Check client max packet size before sending
    version = state.protocol_version || 4

    case Codec.encode_iodata(version, packet) do
      {:ok, data} ->
        encoded_size = IO.iodata_length(data)

        if state.client_max_packet_size && encoded_size > state.client_max_packet_size do
          # Silently drop — client can't handle this packet. Roll back the
          # packet_id allocation so the next outbound message reuses this slot
          # rather than leaking it.
          if qos > 0, do: %{state | next_packet_id: packet_id}, else: state
        else
          state.send_fn.(data)

          # Track outgoing QoS > 0 publishes until the client acknowledges
          # them: they hold Receive Maximum capacity (§3.3.4) and are what a
          # resumed session would have to re-send (§4.4). Nothing re-sends
          # them on this live connection.
          case qos do
            1 ->
              %{state | pending_qos1_tx: Map.put(state.pending_qos1_tx, packet_id, packet)}
              |> track_inflight({:tx1, packet_id}, packet)

            2 ->
              entry = %{phase: :pubrec_pending, packet: packet}
              pending = Map.put(state.pending_qos2_tx, packet_id, entry)
              track_inflight(%{state | pending_qos2_tx: pending}, {:tx2, packet_id}, entry)

            _ ->
              state
          end
        end

      {:error, reason} ->
        Logger.warning("[MqttX.Transport] Failed to encode publish: #{inspect(reason)}")
        state
    end
  end

  # Build CONNACK properties for MQTT 5.0
  defp build_connack_properties(version, _state) when version < 5, do: %{}

  defp build_connack_properties(_version, state) do
    props = %{
      shared_subscription_available: 1,
      topic_alias_maximum: state.server_topic_alias_maximum,
      receive_maximum: state.server_receive_maximum,
      retain_available: 1,
      wildcard_subscription_available: 1,
      subscription_identifier_available: 1
    }

    props =
      if state.server_max_packet_size do
        Map.put(props, :maximum_packet_size, state.server_max_packet_size)
      else
        props
      end

    props =
      if state.server_keep_alive do
        Map.put(props, :server_keep_alive, state.server_keep_alive)
      else
        props
      end

    props
  end

  # Resolve topic alias from PUBLISH properties (MQTT 5.0)
  defp resolve_topic_alias(packet, state) do
    props = Map.get(packet, :properties, %{}) || %{}
    alias_val = Map.get(props, :topic_alias)
    topic = packet.topic

    cond do
      is_nil(alias_val) ->
        {:ok, topic, state}

      alias_val < 1 or alias_val > state.server_topic_alias_maximum ->
        {:error, :topic_alias_invalid, state}

      topic_present?(topic) ->
        # Alias + non-empty topic: store mapping
        new_map = Map.put(state.topic_alias_to_topic, alias_val, topic)
        {:ok, topic, %{state | topic_alias_to_topic: new_map}}

      true ->
        # Alias only: look up stored mapping
        case Map.get(state.topic_alias_to_topic, alias_val) do
          # §3.3.4: empty topic with alias that has no recorded mapping is
          # Protocol Error; close the connection rather than deliver an
          # empty-topic PUBLISH to the user handler.
          nil -> {:error, :topic_alias_invalid, state}
          stored_topic -> {:ok, stored_topic, state}
        end
    end
  end

  defp topic_present?(topic) when is_binary(topic), do: topic != ""
  defp topic_present?(topic) when is_list(topic), do: topic != []
  defp topic_present?(_), do: false

  # Keepalive timer helpers
  defp start_keepalive_timer(%{keep_alive: 0} = state), do: state

  defp start_keepalive_timer(%{keep_alive: keep_alive} = state) do
    timeout_ms = keep_alive * 1500
    timer = Process.send_after(self(), :keepalive_timeout, timeout_ms)
    %{state | keepalive_timer: timer}
  end

  defp reset_keepalive_timer(%{keep_alive: 0} = state), do: state

  defp reset_keepalive_timer(state) do
    state = cancel_keepalive_timer(state)
    start_keepalive_timer(state)
  end

  defp cancel_keepalive_timer(%{keepalive_timer: nil} = state), do: state

  defp cancel_keepalive_timer(%{keepalive_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | keepalive_timer: nil}
  end

  # Idle-ceiling timer helpers
  defp reset_idle_timer(%{max_idle_timeout: nil} = state), do: state

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = Process.send_after(self(), :mqtt_idle_timeout, state.max_idle_timeout)
    %{state | idle_timer: timer}
  end

  # ---------- Session State (§4.1) ----------

  # Seconds the session outlives the connection. v5: the Session Expiry
  # Interval (absent = 0), capped by the listener's :max_session_expiry_interval.
  # 3.1.1: CleanSession 1 ends it with the connection; CleanSession 0 would
  # keep it forever, so the cap applies (0xFFFFFFFF when there is none).
  defp session_lifetime(state, protocol_version, sei, clean_session) do
    cap = state.max_session_expiry_interval

    cond do
      protocol_version >= 5 ->
        requested = sei || 0
        if cap && requested > cap, do: cap, else: requested

      clean_session ->
        0

      true ->
        cap || 0xFFFFFFFF
    end
  end

  # Discard (Clean Start 1, §3.1.2.4) or pick up (Clean Start 0) the client's
  # stored session, and record that one exists and is connected — a connected
  # session never expires. Returns what there is to restore, or nil.
  defp begin_session(state, packet, protocol_version, lifetime) do
    sessions = state.sessions
    client_id = packet.client_id

    resumed =
      cond do
        packet.clean_session ->
          SessionStore.delete(sessions, client_id)
          nil

        not SessionStore.exists?(sessions, client_id) ->
          # What a session that moved to another node left here is not one
          SessionStore.drop_moved(sessions, client_id)
          nil

        true ->
          %{
            subscriptions: SessionStore.subscriptions(sessions, client_id),
            inflight: SessionStore.inflight(sessions, client_id)
          }
      end

    # `persistent` tells MqttX.Server.deliver/3 whether a message for this
    # session must go through the queue (it outlives the connection) or may
    # be sent to the connection directly (it ends with it)
    meta = %{
      protocol_version: protocol_version,
      expires_at: :infinity,
      persistent: lifetime > 0,
      lifetime: lifetime,
      # Which of two copies made on both sides of a network split is newer
      began_at: {System.system_time(:microsecond), node()}
    }

    # A session just claimed from another node keeps dropping the copies of
    # messages both nodes matched
    meta =
      case SessionStore.get(sessions, client_id) do
        %{handoff_until: until} -> Map.put(meta, :handoff_until, until)
        _ -> meta
      end

    SessionStore.put(sessions, client_id, meta)

    resumed
  end

  defp restore_session(state, nil), do: state

  defp restore_session(state, %{subscriptions: subscriptions, inflight: inflight}) do
    # Subscriptions back into this connection's router
    {router, filters} =
      Enum.reduce(subscriptions, {state.router, state.subscribed_filters}, fn
        %{filter: filter, opts: opts}, {router, filters} ->
          {Router.subscribe(router, filter, state.client_id, Map.to_list(opts)),
           MapSet.put(filters, filter)}
      end)

    state = %{state | router: router, subscribed_filters: filters}
    version = state.protocol_version

    # In-flight QoS 1/2 state, oldest first (§4.6). Outbound messages are
    # re-sent as a resumption allows (MQTT-4.4.0-1): a PUBLISH not yet
    # acknowledged with DUP set, a PUBREL whose PUBCOMP never came as is. An
    # inbound QoS 2 message still waiting for its PUBREL is simply held again.
    Enum.reduce(inflight, state, fn
      {{:tx1, id}, packet}, st ->
        send_packet(st, %{packet | dup: true}, version)
        %{st | pending_qos1_tx: Map.put(st.pending_qos1_tx, id, packet)}

      {{:tx2, id}, %{phase: :pubrec_pending, packet: packet} = entry}, st ->
        send_packet(st, %{packet | dup: true}, version)
        %{st | pending_qos2_tx: Map.put(st.pending_qos2_tx, id, entry)}

      {{:tx2, id}, %{phase: :pubrel_sent} = entry}, st ->
        send_packet(st, %{type: :pubrel, packet_id: id}, version)
        %{st | pending_qos2_tx: Map.put(st.pending_qos2_tx, id, entry)}

      {{:rx2, id}, {_packet, _opts} = held}, st ->
        %{
          st
          | pending_qos2_rx: Map.put(st.pending_qos2_rx, id, held),
            inflight_count: st.inflight_count + 1
        }
    end)
  end

  # The connection is over: decide what becomes of the session, once. Nothing
  # to decide if a newer connection took it (§3.1.4) — it is theirs now.
  defp end_connection_session(%{session_finished: true} = state), do: state

  defp end_connection_session(%{session_handed_over: true} = state) do
    leave_registry(state)
    %{state | session_finished: true}
  end

  defp end_connection_session(state) do
    leave_registry(state)
    state = %{state | session_finished: true}
    sessions = state.sessions
    client_id = state.client_id
    lifetime = state.session_lifetime

    cond do
      # Ends with the connection (Session Expiry Interval 0 / CleanSession 1)
      lifetime == 0 ->
        SessionStore.delete(sessions, client_id)

        if state.session_expiry_interval == 0 and state.handler_has_handle_session_expired do
          state.handler.handle_session_expired(client_id, state.handler_state)
        end

        state

      # Outlives it: what was waiting for the Receive Maximum window joins the
      # queue MqttX.Server.deliver/3 fills while the client is away, and the
      # expiry clock starts — a reconnect cancels it (complete_connect/5)
      true ->
        state = flush_outbound_queue_to_store(state)

        if lifetime == 0xFFFFFFFF do
          SessionStore.set_expiry(sessions, client_id, :infinity)
        else
          SessionStore.set_expiry(sessions, client_id, System.system_time(:second) + lifetime)
          handler = if state.handler_has_handle_session_expired, do: state.handler

          # Beyond the timer's reach the store's own expiry check takes over
          if lifetime * 1000 <= @max_timer_ms do
            SessionExpiry.schedule(
              timer_scope(state, client_id),
              lifetime * 1000,
              handler,
              state.handler_state,
              fn -> SessionStore.delete(sessions, client_id) end
            )
          end
        end

        state
    end
  end

  # No longer a delivery target: from here on MqttX.Server.deliver/3 treats
  # the session as not connected (the registry would also clear this entry
  # when the process exits, a moment later)
  defp leave_registry(%{client_id: client_id} = state) when is_binary(client_id) do
    Registry.unregister(MqttX.Server.ConnectionRegistry, timer_scope(state, client_id))
    :ok
  end

  defp leave_registry(_state), do: :ok

  defp flush_outbound_queue_to_store(state) do
    state.outbound_queue
    |> :queue.to_list()
    |> Enum.each(fn entry ->
      SessionStore.enqueue(state.sessions, state.client_id, entry, state.max_outbound_queue)
    end)

    %{state | outbound_queue: :queue.new()}
  end

  # In-flight state is mirrored to the store only when the session will
  # outlive this connection — that is what a resumption restores from
  defp track_inflight(%{persistent: true} = state, key, value) do
    SessionStore.put_inflight(state.sessions, state.client_id, key, value)
    state
  end

  defp track_inflight(state, _key, _value), do: state

  defp untrack_inflight(%{persistent: true} = state, key) do
    SessionStore.delete_inflight(state.sessions, state.client_id, key)
    state
  end

  defp untrack_inflight(state, _key), do: state

  # The subscriptions of the session a Clean Start 0 CONNECT would resume, or
  # nil if there is none: here, on another node, or in the durable backend
  defp peek_session(state, client_id) do
    sessions = state.sessions

    cond do
      SessionStore.exists?(sessions, client_id) ->
        SessionStore.subscriptions(sessions, client_id)

      match?({:ok, _}, remote = remote_lookup(sessions, client_id)) ->
        elem(remote, 1)

      record = SessionStore.load(sessions, client_id) ->
        record.subscriptions

      true ->
        nil
    end
  end

  defp remote_lookup(%{listener: nil}, _client_id), do: :none
  defp remote_lookup(sessions, client_id), do: Cluster.lookup(sessions.listener, client_id)

  # Bring a session held elsewhere here before begin_session/4 reads the
  # store: another node hands it over (and drops its connection and timers
  # for the client), or — with no node holding it — the durable backend has
  # it. Clean Start 1 has the other nodes discard theirs instead.
  defp claim_session(state, packet) do
    sessions = state.sessions
    client_id = packet.client_id
    listener = sessions.listener

    remote =
      cond do
        not Cluster.clustered?(listener) ->
          :none

        packet.clean_session ->
          Cluster.claim(listener, client_id, :clean)

        true ->
          # Whatever the node holding the session forwards while it answers
          # is queued here, and copies arriving both ways are dropped
          until = Cluster.handoff_until()

          if SessionStore.exists?(sessions, client_id),
            do: SessionStore.mark_handoff(sessions, client_id, until),
            else: SessionStore.hold(sessions, client_id, until)

          Cluster.claim(listener, client_id, :take)
      end

    cond do
      packet.clean_session or SessionStore.exists?(sessions, client_id) ->
        :ok

      match?({:ok, _}, remote) ->
        record = elem(remote, 1)

        # Imported where what its old node forwards arrives, which goes ahead
        # of what this node matches for it
        case record do
          %{from: _} -> Cluster.import_moved(listener, client_id, record)
          _ -> SessionStore.import(sessions, client_id, record)
        end

      record = SessionStore.load(sessions, client_id) ->
        SessionStore.import(sessions, client_id, record)

      true ->
        :ok
    end
  end

  # A stored subscription in the shape handle_connect/4 reports it
  defp subscription_info(%{filter: filter, opts: opts}) do
    %{
      topic: filter,
      qos: Map.get(opts, :qos, 0),
      no_local: Map.get(opts, :no_local, false),
      retain_as_published: Map.get(opts, :retain_as_published, false),
      subscription_identifier: Map.get(opts, :subscription_identifier)
    }
  end

  # Extract will message from CONNECT packet
  defp extract_will_message(%{will: nil}), do: nil

  defp extract_will_message(%{will: will}) when is_map(will) do
    will_props = Map.get(will, :properties, %{}) || %{}
    delay_interval = Map.get(will_props, :will_delay_interval, 0) || 0

    %{
      topic: Map.get(will, :topic),
      payload: Map.get(will, :payload, <<>>),
      qos: Map.get(will, :qos, 0),
      retain: Map.get(will, :retain, false),
      delay_interval: delay_interval,
      # The rest become the Will's PUBLISH properties; Will Delay Interval is
      # a Will Property only (§2.2.2.2) and would fail the PUBLISH's encoding
      properties: Map.delete(will_props, :will_delay_interval)
    }
  end

  defp extract_will_message(_), do: nil

  # Maybe publish will message, respecting will_delay_interval
  defp maybe_publish_will(%{will_message: nil}), do: :ok

  defp maybe_publish_will(%{will_message: %{delay_interval: delay}} = state) when delay > 0 do
    # §3.1.2.5: the Will is published at the EARLIER of the delay expiring or
    # the session ending. With session expiry 0 (or unset, which means 0 in
    # v5) the session ends at disconnect — publish immediately.
    session_expiry = state.session_lifetime

    if session_expiry == 0 do
      do_publish_will(state)
    else
      # Hand off to MqttX.Server.WillDelay so the timer survives this
      # connection process exiting AND can be cancelled if the same client_id
      # reconnects within delay_interval (§3.1.3.2.2).
      ctx = %{
        retained_table: state.retained_table,
        listener: state.sessions.listener,
        # What MqttX.Server.deliver/3 finds in this process, so a handler
        # that delivers from handle_publish/4 can still do so when the Will
        # is published from WillDelay's
        delivery: Process.get(:mqttx_listener),
        handler: state.handler,
        handler_state: state.handler_state,
        max_retained_messages: state.max_retained_messages
      }

      MqttX.Server.WillDelay.schedule(
        # The same scope complete_connect/5 cancels under
        timer_scope(state, state.client_id),
        state.will_message,
        will_delay_ms(min(delay, session_expiry)),
        ctx
      )

      :ok
    end
  end

  defp maybe_publish_will(state) do
    do_publish_will(state)
  end

  # Both inputs arrive from 32-bit unsigned properties, so they are already
  # non-negative integers — but nothing in the types enforces it, and a float or
  # negative reaching Process.send_after would crash the (supervised) WillDelay
  # process and silently drop the Will. Enforce the invariant at the boundary.
  defp will_delay_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1000
  defp will_delay_ms(_), do: 0

  defp do_publish_will(state) do
    will = state.will_message
    will_props = Map.get(will, :properties, %{}) || %{}

    opts = %{
      qos: will.qos,
      retain: will.retain,
      dup: false,
      packet_id: nil,
      properties: will_props
    }

    # The Will's topic, payload and retain flag come from the client's CONNECT
    # and are never seen by handle_connect, so handle_publish is the only place
    # that can authorize them. Ask first and store only on acceptance — storing
    # first let a peer that passed CONNECT write (or, with an empty payload,
    # delete) a retained message on any topic its ACL forbids, which
    # deliver_retained_messages/2 would later hand to subscribers unmediated.
    result = state.handler.handle_publish(will.topic, will.payload, opts, state.handler_state)

    if will.retain and match?({:ok, _}, result) do
      store_retained_message(
        %{topic: will.topic, payload: will.payload, qos: will.qos, properties: will_props},
        state
      )
    end

    result
  end

  # Handle retained message storage
  # Runs only after the user handler accepted the publish. Storage rules
  # (empty-payload clear, :max_retained_messages cap, expiry bookkeeping)
  # live in MqttX.Server.RetainedStore.
  defp store_retained_message(packet, state) do
    # Replicated to the other nodes of the listener's group
    Cluster.store_retained(
      state.sessions.listener,
      state.retained_table,
      packet.topic,
      packet.payload,
      packet.qos,
      Map.get(packet, :properties),
      state.max_retained_messages
    )
  end

  # Deliver retained messages matching subscribed topics. State is threaded so
  # we can allocate packet IDs from the real next_packet_id counter rather than
  # `:rand.uniform/1` (which used to collide with the QoS sequence allocator
  # and break ack matching).
  defp deliver_retained_messages(state, topics) do
    now = System.system_time(:second)

    Enum.reduce(topics, state, fn sub, st ->
      matches = MqttX.Server.RetainedStore.match(st.retained_table, get_topic_filter(sub))

      Enum.reduce(matches, st, fn {topic, payload, qos, timestamp, expiry_interval}, st ->
        send_retained(st, topic, payload, qos, timestamp, expiry_interval, sub, now)
      end)
    end)
  end

  defp send_retained(state, topic, payload, qos, timestamp, expiry_interval, sub, now) do
    # retain_handling (§3.8.3.1): 2 = never send on subscribe;
    # 1 = send only if this subscription did not already exist
    retain_handling = Map.get(sub, :retain_handling, 0)
    already_subscribed = Map.get(sub, :already_subscribed, false)

    if retain_handling == 2 or (retain_handling == 1 and already_subscribed) do
      state
    else
      sub_qos = Map.get(sub, :qos, 0)
      effective_qos = min(qos, sub_qos)

      remaining_expiry =
        case {timestamp, expiry_interval} do
          {nil, _} -> nil
          {_, nil} -> nil
          {ts, exp} -> max(0, exp - (now - ts))
        end

      properties =
        if remaining_expiry,
          do: %{message_expiry_interval: remaining_expiry},
          else: %{}

      # §3.3.2.3.8: retained messages sent on subscribe carry the
      # subscription's Subscription Identifier, if the SUBSCRIBE had one
      properties =
        case Map.get(sub, :subscription_identifier) do
          nil -> properties
          id -> Map.put(properties, :subscription_identifier, id)
        end

      # Route through send_publish so QoS > 0 retained deliveries are tracked
      # in the in-flight maps (PUBREC/PUBACK matching, Receive Maximum) and
      # respect the client's Receive Maximum — a bare send used to leave the
      # QoS 2 handshake permanently incomplete.
      send_publish(state, topic, payload, %{
        qos: effective_qos,
        retain: true,
        properties: properties
      })
    end
  end

  defp get_topic_filter(%{topic: topic}), do: topic
  defp get_topic_filter(topic) when is_binary(topic), do: topic
  defp get_topic_filter(topic) when is_list(topic), do: MqttX.Topic.flatten(topic)

  # Canonical string form of a subscription's topic filter (for the
  # subscribed_filters set)
  defp filter_key(sub), do: sub |> get_topic_filter() |> MqttX.Topic.flatten()
end
