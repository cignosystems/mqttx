defmodule MqttX.Transport.Handler do
  @moduledoc false

  # Shared MQTT protocol state machine for all transport adapters.
  # This is a pure functional module — no `use GenServer`, no framework dependency.
  # Each transport constructs a `send_fn` closure at connection time.

  alias MqttX.Packet.Codec
  alias MqttX.Telemetry

  require Logger

  # ---------- Public API ----------

  @doc """
  Build initial protocol state. Returns `{:error, :rate_limited}` if rate limited.
  """
  def init(handler, handler_opts, retained_table, rate_limiter, send_fn) do
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
      will_message: nil,
      graceful_disconnect: false,
      connected: false,
      keep_alive: 0,
      keepalive_timer: nil,
      session_expiry_interval: nil,
      pending_qos2_rx: %{},
      pending_qos2_tx: %{},
      # Outgoing QoS 1 packets awaiting PUBACK (§4.4 / §4.6).
      # Each entry: {packet, sent_at_ms, retries}.
      pending_qos1_tx: %{},
      next_packet_id: 1,
      # QoS 2 retry
      qos2_retry_timer: nil,
      qos2_retry_interval: Map.get(transport_opts, :qos2_retry_interval, 5000),
      qos2_max_retries: Map.get(transport_opts, :qos2_max_retries, 3),
      # Topic aliases (MQTT 5.0)
      topic_alias_to_topic: %{},
      server_topic_alias_maximum: Map.get(transport_opts, :topic_alias_maximum, 100),
      client_topic_alias_maximum: 0,
      # Flow control
      server_receive_maximum: Map.get(transport_opts, :receive_maximum, 65535),
      client_receive_maximum: 65535,
      inflight_count: 0,
      # Max packet size
      server_max_packet_size: Map.get(transport_opts, :max_packet_size, nil),
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
      handler_has_handle_session_expired: function_exported?(handler, :handle_session_expired, 2)
    }

    {:ok, state}
  catch
    :connection_rate_limited -> {:error, :rate_limited}
  end

  @doc """
  Process incoming binary data (buffer accumulation + decode loop).
  """
  def handle_data(data, state) do
    buffer =
      case state.buffer do
        <<>> -> data
        buf -> buf <> data
      end

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

    if connected and state.handler do
      state.handler.handle_disconnect(:closed, state.handler_state)
    end

    if connected and not graceful do
      maybe_start_session_expiry(state)
    end

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

    if state.connected and state.handler do
      state.handler.handle_disconnect({:error, reason}, state.handler_state)
    end

    if state.connected do
      maybe_start_session_expiry(state)
    end

    {:shutdown, state}
  end

  @doc """
  Idle timeout.
  """
  def handle_timeout(state) do
    Logger.debug("[MqttX.Transport] Connection timeout")

    if state.connected and state.handler do
      state.handler.handle_disconnect(:timeout, state.handler_state)
    end

    {:close, state}
  end

  @doc """
  Out-of-band messages (:keepalive_timeout, {:server_disconnect, ...}, custom).
  """
  def handle_info(:check_qos2_retry, state) do
    now = System.monotonic_time(:millisecond)
    interval = state.qos2_retry_interval
    max_retries = state.qos2_max_retries

    # Retry pending QoS 2 RX (re-send PUBREC)
    {new_rx, dropped_rx} =
      Enum.reduce(state.pending_qos2_rx, {%{}, []}, fn {pid, entry}, {keep, dropped} ->
        {_packet, _opts, ts, retries} =
          case entry do
            {p, o, t, r} -> {p, o, t, r}
            {p, o} -> {p, o, now, 0}
          end

        if now - ts >= interval do
          if retries >= max_retries do
            {keep, [pid | dropped]}
          else
            pubrec = %{type: :pubrec, packet_id: pid}
            send_packet(state, pubrec, state.protocol_version)

            case entry do
              {p, o, _t, r} -> {Map.put(keep, pid, {p, o, now, r + 1}), dropped}
              {p, o} -> {Map.put(keep, pid, {p, o, now, 1}), dropped}
            end
          end
        else
          {Map.put(keep, pid, entry), dropped}
        end
      end)

    # Retry pending QoS 2 TX (re-send PUBLISH with dup or PUBREL)
    {new_tx, dropped_tx} =
      Enum.reduce(state.pending_qos2_tx, {%{}, []}, fn {pid, entry}, {keep, dropped} ->
        {phase, packet, ts, retries} =
          case entry do
            %{phase: ph, packet: pk, timestamp: t, retries: r} -> {ph, pk, t, r}
            :pubrec_pending -> {:pubrec_pending, nil, now, 0}
            :pubrel_sent -> {:pubrel_sent, nil, now, 0}
          end

        if now - ts >= interval do
          if retries >= max_retries do
            {keep, [pid | dropped]}
          else
            case phase do
              :pubrec_pending when not is_nil(packet) ->
                dup_packet = %{packet | dup: true}
                send_packet(state, dup_packet, state.protocol_version)

                {Map.put(keep, pid, %{
                   phase: :pubrec_pending,
                   packet: packet,
                   timestamp: now,
                   retries: retries + 1
                 }), dropped}

              :pubrel_sent ->
                pubrel = %{type: :pubrel, packet_id: pid}
                send_packet(state, pubrel, state.protocol_version)

                {Map.put(keep, pid, %{
                   phase: :pubrel_sent,
                   packet: packet,
                   timestamp: now,
                   retries: retries + 1
                 }), dropped}

              _ ->
                {Map.put(keep, pid, entry), dropped}
            end
          end
        else
          {Map.put(keep, pid, entry), dropped}
        end
      end)

    # Retry pending QoS 1 TX (re-send PUBLISH with DUP=true).
    # §4.4: a session that resumes outstanding QoS 1 PUBLISH packets MUST
    # set the DUP flag on retransmission. Drop after qos2_max_retries.
    {new_qos1_tx, _dropped_qos1_tx} =
      Enum.reduce(state.pending_qos1_tx, {%{}, []}, fn {pid, {packet, ts, retries}},
                                                       {keep, dropped} ->
        if now - ts >= interval do
          if retries >= max_retries do
            {keep, [pid | dropped]}
          else
            dup_packet = %{packet | dup: true}
            send_packet(state, dup_packet, state.protocol_version)
            {Map.put(keep, pid, {packet, now, retries + 1}), dropped}
          end
        else
          {Map.put(keep, pid, {packet, ts, retries}), dropped}
        end
      end)

    inflight_adj = length(dropped_rx)
    new_inflight = max(state.inflight_count - inflight_adj, 0)

    _ = dropped_tx

    state = %{
      state
      | pending_qos2_rx: new_rx,
        pending_qos2_tx: new_tx,
        pending_qos1_tx: new_qos1_tx,
        inflight_count: new_inflight
    }

    {:noreply, schedule_qos2_retry_timer(state)}
  end

  def handle_info(:keepalive_timeout, state) do
    Logger.debug("[MqttX.Transport] Keepalive timeout for #{state.client_id}")

    state =
      if state.connected and not is_nil(state.will_message) do
        maybe_publish_will(state)
        # Clear the will so handle_close/terminate doesn't publish it a second
        # time (§3.1.2.5 — Will is delivered exactly once on abnormal close).
        %{state | will_message: nil}
      else
        state
      end

    if state.connected and state.handler do
      state.handler.handle_disconnect(:keepalive_timeout, state.handler_state)
    end

    {:stop, :normal, state}
  end

  def handle_info({:server_disconnect, reason_code, properties}, state) do
    send_disconnect(state, reason_code, properties)

    if state.connected and state.handler do
      state.handler.handle_disconnect({:server_disconnect, reason_code}, state.handler_state)
    end

    {:stop, :normal, %{state | graceful_disconnect: true}}
  end

  def handle_info(message, state) do
    if state.connected and state.handler_has_handle_info do
      case state.handler.handle_info(message, state.handler_state) do
        {:ok, new_handler_state} ->
          {:noreply, %{state | handler_state: new_handler_state}}

        {:publish, topic, payload, new_handler_state} ->
          new_state =
            send_publish(%{state | handler_state: new_handler_state}, topic, payload, %{
              qos: 0,
              retain: false
            })

          {:noreply, new_state}

        {:publish, topic, payload, opts, new_handler_state} ->
          new_state =
            send_publish(%{state | handler_state: new_handler_state}, topic, payload, opts)

          {:noreply, new_state}

        {:disconnect, reason_code, new_handler_state} ->
          send_disconnect(state, reason_code, %{})
          state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

          {:stop, :normal, %{state | handler_state: new_handler_state, graceful_disconnect: true}}

        {:disconnect, reason_code, properties, new_handler_state} ->
          send_disconnect(state, reason_code, properties)
          state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

          {:stop, :normal, %{state | handler_state: new_handler_state, graceful_disconnect: true}}

        {:stop, _reason, new_handler_state} ->
          {:stop, :normal, %{state | handler_state: new_handler_state}}
      end
    else
      {:noreply, state}
    end
  end

  # ---------- Private functions ----------

  # Process incoming data buffer
  defp process_buffer(buffer, state) do
    version = state.protocol_version || 4

    case Codec.decode(version, buffer) do
      {:ok, {packet, rest}} ->
        # Check max packet size (raw bytes = buffer size - rest size)
        raw_size = byte_size(buffer) - byte_size(rest)

        if state.server_max_packet_size && raw_size > state.server_max_packet_size do
          send_disconnect(state, 0x95, %{})
          {:close, :packet_too_large, %{state | buffer: rest, graceful_disconnect: true}}
        else
          case handle_packet(packet, state) do
            {:ok, new_state} ->
              process_buffer(rest, %{reset_keepalive_timer(new_state) | buffer: rest})

            {:close, reason, new_state} ->
              {:close, reason, %{new_state | buffer: rest}}
          end
        end

      {:error, :incomplete} ->
        {:ok, %{state | buffer: buffer}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Reject any non-CONNECT/AUTH packet before CONNECT is processed (MQTT spec requirement)
  defp handle_packet(%{type: type} = _packet, %{connected: false} = state)
       when type not in [:connect, :auth] do
    send_disconnect(state, 0x82, %{})
    {:close, :protocol_error, state}
  end

  # Handle CONNECT
  defp handle_packet(%{type: :connect} = packet, state) do
    protocol_version = packet.protocol_version

    # §3.1.3.2.2: a fresh CONNECT cancels any in-flight Will Delay for this
    # client_id from the previous abnormal disconnect.
    if packet.client_id not in [nil, ""] do
      MqttX.Server.WillDelay.cancel(packet.client_id)
    end

    telemetry_meta = %{client_id: packet.client_id, protocol_version: protocol_version}
    start_time = System.monotonic_time()
    Telemetry.server_client_connect_start(telemetry_meta)

    if protocol_version not in state.supported_versions do
      # §3.2.2.2: reject with Unacceptable Protocol Version. v5 uses 0x84;
      # earlier versions use 0x01.
      reason_code = if protocol_version >= 5, do: 0x84, else: 0x01

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
      do_handle_connect_authorized(packet, state, telemetry_meta, start_time)
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
        send_disconnect(state, 0x94, %{})
        {:close, {:server_disconnect, 0x94}, %{state | graceful_disconnect: true}}
    end
  catch
    {:message_rate_limited, rate_limited_packet, current_state} ->
      if rate_limited_packet.qos == 1 do
        puback = %{
          type: :puback,
          packet_id: rate_limited_packet.packet_id,
          reason_code: 0x96,
          properties: %{}
        }

        send_packet(current_state, puback, current_state.protocol_version)
      end

      if rate_limited_packet.qos == 2 do
        pubrec = %{
          type: :pubrec,
          packet_id: rate_limited_packet.packet_id,
          reason_code: 0x96,
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
        acks = Enum.map(granted_qos, fn qos -> {:ok, qos} end)

        suback = %{
          type: :suback,
          packet_id: packet.packet_id,
          acks: acks,
          properties: %{}
        }

        send_packet(state, suback, state.protocol_version)

        state = deliver_retained_messages(state, packet.topics)

        {:ok, %{state | handler_state: new_handler_state}}

      {:disconnect, reason_code, new_handler_state} ->
        send_disconnect(state, reason_code, %{})
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{state | handler_state: new_handler_state, graceful_disconnect: true}}

      {:disconnect, reason_code, properties, new_handler_state} ->
        send_disconnect(state, reason_code, properties)
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{state | handler_state: new_handler_state, graceful_disconnect: true}}
    end
  end

  # Handle UNSUBSCRIBE
  defp handle_packet(%{type: :unsubscribe} = packet, state) do
    handler = state.handler

    case handler.handle_unsubscribe(packet.topics, state.handler_state) do
      {:ok, new_handler_state} ->
        acks = Enum.map(packet.topics, fn _ -> {:ok, :found} end)

        unsuback = %{
          type: :unsuback,
          packet_id: packet.packet_id,
          acks: acks,
          properties: %{}
        }

        send_packet(state, unsuback, state.protocol_version)
        {:ok, %{state | handler_state: new_handler_state}}

      {:disconnect, reason_code, new_handler_state} ->
        send_disconnect(state, reason_code, %{})
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{state | handler_state: new_handler_state, graceful_disconnect: true}}

      {:disconnect, reason_code, properties, new_handler_state} ->
        send_disconnect(state, reason_code, properties)
        handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

        {:close, {:server_disconnect, reason_code},
         %{state | handler_state: new_handler_state, graceful_disconnect: true}}
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
    state = cancel_qos2_retry_timer(state)

    reason_code = Map.get(packet, :reason_code, 0)

    Telemetry.server_client_disconnect(%{client_id: state.client_id, reason: :normal})

    state =
      if reason_code == 0x04 and not is_nil(state.will_message) do
        maybe_publish_will(state)
        %{state | will_message: nil}
      else
        state
      end

    if state.handler do
      state.handler.handle_disconnect(:normal, state.handler_state)
    end

    maybe_start_session_expiry(state)

    {:close, :disconnect, %{state | graceful_disconnect: true}}
  end

  # Handle PUBACK (for QoS 1 outgoing messages)
  defp handle_packet(%{type: :puback} = packet, state) do
    pending_qos1_tx = Map.delete(state.pending_qos1_tx, packet.packet_id)

    if state.handler_has_handle_puback do
      case state.handler.handle_puback(packet.packet_id, state.handler_state) do
        {:ok, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state, pending_qos1_tx: pending_qos1_tx}}
      end
    else
      {:ok, %{state | pending_qos1_tx: pending_qos1_tx}}
    end
  end

  # Handle PUBREC (client acknowledges receipt of outgoing QoS 2 PUBLISH)
  defp handle_packet(%{type: :pubrec} = packet, state) do
    case Map.get(state.pending_qos2_tx, packet.packet_id) do
      nil ->
        # Unknown packet_id, ignore
        {:ok, state}

      %{phase: :pubrel_sent} ->
        # §4.3.3 figure 4.4: a duplicate PUBREC after PUBREL has already been
        # sent must NOT trigger another PUBREL. Wait for the original PUBCOMP.
        {:ok, state}

      _entry ->
        # Send PUBREL to complete the QoS 2 handshake
        pubrel = %{type: :pubrel, packet_id: packet.packet_id}
        send_packet(state, pubrel, state.protocol_version)
        now = System.monotonic_time(:millisecond)

        pending =
          Map.put(state.pending_qos2_tx, packet.packet_id, %{
            phase: :pubrel_sent,
            packet: nil,
            timestamp: now,
            retries: 0
          })

        {:ok, %{state | pending_qos2_tx: pending}}
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
          reason_code: 0x92,
          properties: %{}
        }

        send_packet(state, pubcomp, state.protocol_version)
        {:ok, state}

      {entry, remaining} when is_tuple(entry) ->
        # Extract packet and opts from either {packet, opts} or {packet, opts, ts, retries}
        {stored_packet, opts} =
          case entry do
            {p, o, _ts, _r} -> {p, o}
            {p, o} -> {p, o}
          end

        # Now deliver the message to the handler
        handler = state.handler

        case handler.handle_publish(
               stored_packet.topic,
               stored_packet.payload,
               opts,
               state.handler_state
             ) do
          {:ok, new_handler_state} ->
            pubcomp = %{type: :pubcomp, packet_id: packet.packet_id}
            send_packet(state, pubcomp, state.protocol_version)

            {:ok,
             %{
               state
               | handler_state: new_handler_state,
                 pending_qos2_rx: remaining,
                 inflight_count: max(state.inflight_count - 1, 0)
             }}

          {:error, _reason, new_handler_state} ->
            pubcomp = %{type: :pubcomp, packet_id: packet.packet_id}
            send_packet(state, pubcomp, state.protocol_version)

            {:ok,
             %{
               state
               | handler_state: new_handler_state,
                 pending_qos2_rx: remaining,
                 inflight_count: max(state.inflight_count - 1, 0)
             }}

          {:disconnect, reason_code, new_handler_state} ->
            send_disconnect(state, reason_code, %{})
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}

          {:disconnect, reason_code, properties, new_handler_state} ->
            send_disconnect(state, reason_code, properties)
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}
        end
    end
  end

  # Handle PUBCOMP (client confirms QoS 2 outgoing flow complete)
  defp handle_packet(%{type: :pubcomp} = packet, state) do
    pending = Map.delete(state.pending_qos2_tx, packet.packet_id)

    if state.handler_has_handle_puback do
      case state.handler.handle_puback(packet.packet_id, state.handler_state) do
        {:ok, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state, pending_qos2_tx: pending}}
      end
    else
      {:ok, %{state | pending_qos2_tx: pending}}
    end
  end

  # Handle AUTH (MQTT 5.0 enhanced authentication)
  # §4.12: AUTH packets are only valid (a) within an in-progress enhanced-auth
  # exchange started by CONNECT carrying Authentication Method, or (b) for
  # re-authentication on an already-connected session. Receiving an AUTH packet
  # with no preceding CONNECT and no enhanced-auth context is a Protocol Error.
  defp handle_packet(%{type: :auth}, %{connected: false, protocol_version: nil} = state) do
    send_disconnect(state, 0x82, %{})
    {:close, :protocol_error, state}
  end

  defp handle_packet(%{type: :auth} = packet, state) do
    if state.handler_has_handle_auth do
      method = get_in(packet, [:properties, :authentication_method]) || ""
      data = get_in(packet, [:properties, :authentication_data])

      case state.handler.handle_auth(method, data, state.handler_state) do
        {:ok, new_handler_state} ->
          connack = %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          }

          send_packet(state, connack, state.protocol_version)
          {:ok, %{state | handler_state: new_handler_state, connected: true}}

        {:continue, response_data, new_handler_state} ->
          auth_resp = %{
            type: :auth,
            reason_code: 0x18,
            properties: %{
              authentication_method: method,
              authentication_data: response_data
            }
          }

          send_packet(state, auth_resp, state.protocol_version)
          {:ok, %{state | handler_state: new_handler_state}}

        {:error, reason_code, new_handler_state} ->
          connack = %{
            type: :connack,
            session_present: false,
            reason_code: reason_code,
            properties: %{}
          }

          send_packet(state, connack, state.protocol_version)
          {:close, :auth_failed, %{state | handler_state: new_handler_state}}
      end
    else
      connack = %{
        type: :connack,
        session_present: false,
        reason_code: 0x8C,
        properties: %{}
      }

      send_packet(state, connack, state.protocol_version)
      {:close, :auth_not_supported, state}
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

    credentials = %{
      username: packet.username,
      password: packet.password
    }

    connect_info = %{
      protocol_version: protocol_version,
      keep_alive: Map.get(packet, :keep_alive, 0)
    }

    # Extract client properties (MQTT 5.0)
    connect_props = Map.get(packet, :properties, %{}) || %{}
    client_topic_alias_max = Map.get(connect_props, :topic_alias_maximum, 0)
    client_receive_max = Map.get(connect_props, :receive_maximum, 65535)
    client_max_packet_size = Map.get(connect_props, :maximum_packet_size, nil)

    connect_result =
      if state.handler_has_handle_connect4 do
        handler.handle_connect(packet.client_id, credentials, connect_info, state.handler_state)
      else
        handler.handle_connect(packet.client_id, credentials, state.handler_state)
      end

    case connect_result do
      {:ok, new_handler_state} ->
        duration = System.monotonic_time() - start_time
        Telemetry.server_client_connect_stop(duration, telemetry_meta)

        connack_props = build_connack_properties(protocol_version, state)

        connack = %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: connack_props
        }

        send_packet(state, connack, protocol_version)

        will_message = extract_will_message(packet)
        keep_alive = Map.get(packet, :keep_alive, 0) || 0

        # If server overrides keepalive (MQTT 5.0), use that for the timer
        keep_alive =
          if state.server_keep_alive && protocol_version >= 5 do
            state.server_keep_alive
          else
            keep_alive
          end

        session_expiry_interval = get_in(packet, [:properties, :session_expiry_interval])

        new_state = %{
          state
          | protocol_version: protocol_version,
            client_id: packet.client_id,
            handler_state: new_handler_state,
            will_message: will_message,
            connected: true,
            keep_alive: keep_alive,
            session_expiry_interval: session_expiry_interval,
            client_topic_alias_maximum: client_topic_alias_max,
            client_receive_maximum: client_receive_max,
            client_max_packet_size: client_max_packet_size
        }

        {:ok, start_keepalive_timer(start_qos2_retry_timer(new_state))}

      {:error, reason_code, new_handler_state} ->
        duration = System.monotonic_time() - start_time

        Telemetry.server_client_connect_exception(
          duration,
          Map.put(telemetry_meta, :reason_code, reason_code)
        )

        connack = %{
          type: :connack,
          session_present: false,
          reason_code: reason_code,
          properties: %{}
        }

        send_packet(state, connack, protocol_version)
        {:close, :auth_failed, %{state | handler_state: new_handler_state}}
    end
  end

  # Process PUBLISH after topic alias resolution
  defp handle_publish_with_topic(packet, resolved_topic, state) do
    packet = %{packet | topic: resolved_topic}

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

    if packet.retain do
      handle_retained_message(
        packet.topic,
        packet.payload,
        packet.qos,
        packet.properties,
        state.retained_table
      )
    end

    cond do
      # §3.1.2.11.3 / §3.3.4: Receive Maximum bounds the number of in-flight
      # QoS>0 PUBLISH packets a client may have outstanding. Spec permits
      # either a per-message ack with reason 0x93 (Receive Maximum exceeded)
      # or DISCONNECT 0x93. We keep the per-message variant — it preserves
      # the session and is the established behavior tested below.
      packet.qos == 2 and state.inflight_count >= state.server_receive_maximum ->
        pubrec = %{
          type: :pubrec,
          packet_id: packet.packet_id,
          reason_code: 0x93,
          properties: %{}
        }

        send_packet(state, pubrec, state.protocol_version)
        {:ok, state}

      packet.qos == 1 and state.inflight_count >= state.server_receive_maximum ->
        puback = %{
          type: :puback,
          packet_id: packet.packet_id,
          reason_code: 0x93,
          properties: %{}
        }

        send_packet(state, puback, state.protocol_version)
        {:ok, state}

      packet.qos == 2 ->
        # DUP handling: if packet_id already pending, re-send PUBREC without re-storing
        if Map.has_key?(state.pending_qos2_rx, packet.packet_id) do
          pubrec = %{type: :pubrec, packet_id: packet.packet_id}
          send_packet(state, pubrec, state.protocol_version)
          {:ok, state}
        else
          pubrec = %{type: :pubrec, packet_id: packet.packet_id}
          send_packet(state, pubrec, state.protocol_version)

          now = System.monotonic_time(:millisecond)
          pending = Map.put(state.pending_qos2_rx, packet.packet_id, {packet, opts, now, 0})
          {:ok, %{state | pending_qos2_rx: pending, inflight_count: state.inflight_count + 1}}
        end

      true ->
        case handler.handle_publish(packet.topic, packet.payload, opts, state.handler_state) do
          {:ok, new_handler_state} ->
            if packet.qos == 1 do
              puback = %{type: :puback, packet_id: packet.packet_id}
              send_packet(state, puback, state.protocol_version)
            end

            {:ok, %{state | handler_state: new_handler_state}}

          {:error, _reason, new_handler_state} ->
            {:ok, %{state | handler_state: new_handler_state}}

          {:disconnect, reason_code, new_handler_state} ->
            send_disconnect(state, reason_code, %{})
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}

          {:disconnect, reason_code, properties, new_handler_state} ->
            send_disconnect(state, reason_code, properties)
            handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:close, {:server_disconnect, reason_code},
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}
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
        properties: properties
      }

      send_packet(state, packet, state.protocol_version)
    end
  end

  # Send PUBLISH packet to client
  defp send_publish(state, topic, payload, opts) do
    qos = Map.get(opts, :qos, 0)

    {packet_id, state} =
      if qos > 0 do
        id = state.next_packet_id
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

          # Track outgoing QoS>0 publishes for retransmission. The shared
          # `:check_qos2_retry` timer (despite the name) walks both maps and
          # re-sends with DUP=true on stale entries, dropping after
          # qos2_max_retries.
          case qos do
            1 ->
              now = System.monotonic_time(:millisecond)
              pending = Map.put(state.pending_qos1_tx, packet_id, {packet, now, 0})
              %{state | pending_qos1_tx: pending}

            2 ->
              now = System.monotonic_time(:millisecond)

              pending =
                Map.put(state.pending_qos2_tx, packet_id, %{
                  phase: :pubrec_pending,
                  packet: packet,
                  timestamp: now,
                  retries: 0
                })

              %{state | pending_qos2_tx: pending}

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
      subscription_identifier_available: 0
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

  # QoS 2 retry timer helpers
  defp start_qos2_retry_timer(state) do
    schedule_qos2_retry_timer(state)
  end

  defp schedule_qos2_retry_timer(state) do
    timer = Process.send_after(self(), :check_qos2_retry, state.qos2_retry_interval)
    %{state | qos2_retry_timer: timer}
  end

  defp cancel_qos2_retry_timer(%{qos2_retry_timer: nil} = state), do: state

  defp cancel_qos2_retry_timer(%{qos2_retry_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | qos2_retry_timer: nil}
  end

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

  # Session expiry helper
  defp maybe_start_session_expiry(%{session_expiry_interval: nil}), do: :ok
  defp maybe_start_session_expiry(%{session_expiry_interval: 0xFFFFFFFF}), do: :ok

  defp maybe_start_session_expiry(%{session_expiry_interval: 0} = state) do
    if state.handler_has_handle_session_expired do
      state.handler.handle_session_expired(state.client_id, state.handler_state)
    end

    :ok
  end

  defp maybe_start_session_expiry(%{session_expiry_interval: interval} = state)
       when interval > 0 do
    if state.handler_has_handle_session_expired do
      handler = state.handler
      client_id = state.client_id
      handler_state = state.handler_state

      Task.start(fn ->
        Process.sleep(interval * 1000)
        handler.handle_session_expired(client_id, handler_state)
      end)
    end

    :ok
  end

  defp maybe_start_session_expiry(_state), do: :ok

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
      properties: will_props
    }
  end

  defp extract_will_message(_), do: nil

  # Maybe publish will message, respecting will_delay_interval
  defp maybe_publish_will(%{will_message: nil}), do: :ok

  defp maybe_publish_will(%{will_message: %{delay_interval: delay}} = state) when delay > 0 do
    # Hand off to MqttX.Server.WillDelay so the timer survives this connection
    # process exiting AND can be cancelled if the same client_id reconnects
    # within delay_interval (§3.1.3.2.2).
    ctx = %{
      retained_table: state.retained_table,
      handler: state.handler,
      handler_state: state.handler_state
    }

    MqttX.Server.WillDelay.schedule(state.client_id, state.will_message, delay * 1000, ctx)
    :ok
  end

  defp maybe_publish_will(state) do
    do_publish_will(state)
  end

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

    if will.retain do
      handle_retained_message(
        will.topic,
        will.payload,
        will.qos,
        will_props,
        state.retained_table
      )
    end

    state.handler.handle_publish(will.topic, will.payload, opts, state.handler_state)
  end

  # Handle retained message storage
  defp handle_retained_message(topic, <<>>, _qos, _properties, table) do
    topic_key = normalize_topic_key(topic)
    :ets.delete(table, topic_key)
    :ok
  end

  defp handle_retained_message(topic, payload, qos, properties, table) do
    topic_key = normalize_topic_key(topic)
    normalized_list = MqttX.Topic.normalize(topic_key)
    timestamp = System.system_time(:second)
    expiry_interval = Map.get(properties || %{}, :message_expiry_interval)
    :ets.insert(table, {topic_key, normalized_list, payload, qos, timestamp, expiry_interval})
    :ok
  end

  defp normalize_topic_key(topic) when is_list(topic), do: Enum.join(topic, "/")
  defp normalize_topic_key(topic) when is_binary(topic), do: topic

  # Deliver retained messages matching subscribed topics. State is threaded so
  # we can allocate packet IDs from the real next_packet_id counter rather than
  # `:rand.uniform/1` (which used to collide with the QoS sequence allocator
  # and break ack matching).
  defp deliver_retained_messages(state, topics) do
    now = System.system_time(:second)

    normalized_subs =
      Enum.map(topics, fn sub ->
        filter = get_topic_filter(sub)
        normalized = MqttX.Topic.normalize(filter)
        {sub, normalized}
      end)

    {exact_subs, wildcard_subs} =
      Enum.split_with(normalized_subs, fn {_sub, normalized} ->
        not Enum.any?(normalized, fn seg -> seg == :single_level or seg == :multi_level end)
      end)

    {state, expired_keys} =
      Enum.reduce(exact_subs, {state, []}, fn {sub, _normalized}, {st, exp_acc} ->
        topic_key = get_topic_filter(sub)

        topic_key =
          if is_list(topic_key), do: Enum.join(topic_key, "/"), else: to_string(topic_key)

        case :ets.lookup(st.retained_table, topic_key) do
          [{^topic_key, _norm_list, payload, qos, timestamp, expiry_interval}] ->
            if expired?(timestamp, expiry_interval, now) do
              {st, [topic_key | exp_acc]}
            else
              {send_retained(st, topic_key, payload, qos, timestamp, expiry_interval, sub, now),
               exp_acc}
            end

          [{^topic_key, payload, qos, timestamp, expiry_interval}] ->
            if expired?(timestamp, expiry_interval, now) do
              {st, [topic_key | exp_acc]}
            else
              {send_retained(st, topic_key, payload, qos, timestamp, expiry_interval, sub, now),
               exp_acc}
            end

          [{^topic_key, payload, qos}] ->
            {send_retained(st, topic_key, payload, qos, nil, nil, sub, now), exp_acc}

          [] ->
            {st, exp_acc}
        end
      end)

    {state, expired_keys} =
      if wildcard_subs == [] do
        {state, expired_keys}
      else
        :ets.foldl(
          fn entry, {st, expired_acc} ->
            {retained_topic, normalized_topic, payload, qos, timestamp, expiry_interval} =
              case entry do
                {topic, norm, payload, qos, ts, exp} ->
                  {topic, norm, payload, qos, ts, exp}

                {topic, payload, qos, ts, exp} ->
                  {topic, MqttX.Topic.normalize(topic), payload, qos, ts, exp}

                {topic, payload, qos} ->
                  {topic, MqttX.Topic.normalize(topic), payload, qos, nil, nil}
              end

            if expired?(timestamp, expiry_interval, now) do
              {st, [retained_topic | expired_acc]}
            else
              st =
                Enum.reduce(wildcard_subs, st, fn {sub, sub_normalized}, st ->
                  if MqttX.Topic.matches?(sub_normalized, normalized_topic) do
                    send_retained(
                      st,
                      retained_topic,
                      payload,
                      qos,
                      timestamp,
                      expiry_interval,
                      sub,
                      now
                    )
                  else
                    st
                  end
                end)

              {st, expired_acc}
            end
          end,
          {state, expired_keys},
          state.retained_table
        )
      end

    Enum.each(expired_keys, fn key -> :ets.delete(state.retained_table, key) end)
    state
  end

  defp expired?(nil, _, _now), do: false
  defp expired?(_, nil, _now), do: false
  defp expired?(ts, exp, now), do: now - ts > exp

  defp send_retained(state, topic, payload, qos, timestamp, expiry_interval, sub, now) do
    # Check retain_handling: 2 = don't send retained messages on subscribe
    retain_handling = Map.get(sub, :retain_handling, 0)

    if retain_handling == 2 do
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

      {packet_id, state} =
        if effective_qos > 0 do
          id = state.next_packet_id
          next = if id >= 65_535, do: 1, else: id + 1
          {id, %{state | next_packet_id: next}}
        else
          {nil, state}
        end

      packet = %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: effective_qos,
        retain: true,
        dup: false,
        packet_id: packet_id,
        properties: properties
      }

      send_packet(state, packet, state.protocol_version)
      state
    end
  end

  defp get_topic_filter(%{topic: topic}), do: topic
  defp get_topic_filter(topic) when is_binary(topic), do: topic
  defp get_topic_filter(topic) when is_list(topic), do: Enum.join(topic, "/")
end
