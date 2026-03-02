defmodule MqttX.Transport.Ranch do
  @moduledoc """
  Ranch transport adapter for MqttX.

  This adapter uses Ranch as the underlying TCP/TLS server.

  ## Usage

      MqttX.Server.start_link(MyHandler, handler_opts,
        transport: MqttX.Transport.Ranch,
        port: 1883
      )

  ## Options

  - `:port` - Port to listen on (default: 1883)
  - `:num_acceptors` - Number of acceptor processes (default: 100)
  - `:transport` - Ranch transport (`:ranch_tcp` or `:ranch_ssl`)
  - `:transport_options` - SSL/TLS options when using `:ranch_ssl`
  """

  @behaviour MqttX.Transport

  require Logger

  @default_port 1883
  @default_num_acceptors 100

  @impl MqttX.Transport
  def start_link(handler, handler_opts, transport_opts) do
    port = Keyword.get(transport_opts, :port, @default_port)
    num_acceptors = Keyword.get(transport_opts, :num_acceptors, @default_num_acceptors)
    ranch_transport = Keyword.get(transport_opts, :transport, :ranch_tcp)
    ranch_opts = Keyword.get(transport_opts, :transport_options, [])

    # Create ETS table for retained messages
    retained_table = create_retained_table(port)

    # Create rate limiter if configured
    rate_limiter =
      case Keyword.get(transport_opts, :rate_limit) do
        nil -> nil
        rate_limit_opts -> MqttX.Server.RateLimiter.new(rate_limit_opts)
      end

    ref = make_ref()

    protocol_opts = %{
      handler: handler,
      handler_opts: handler_opts,
      transport_opts: transport_opts,
      retained_table: retained_table,
      rate_limiter: rate_limiter
    }

    transport_opts_full = [{:port, port} | ranch_opts]

    Logger.info("[MqttX.Transport.Ranch] Starting on port #{port}")

    :ranch.start_listener(
      ref,
      ranch_transport,
      %{socket_opts: transport_opts_full, num_acceptors: num_acceptors},
      __MODULE__.Protocol,
      protocol_opts
    )
  end

  defp create_retained_table(port) do
    table_name = :"mqttx_ranch_retained_#{port}"

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])

      _ref ->
        table_name
    end
  end

  @impl MqttX.Transport
  def send(socket, data) do
    :gen_tcp.send(socket, data)
  end

  @impl MqttX.Transport
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  @impl MqttX.Transport
  def peername(socket) do
    :inet.peername(socket)
  end

  @impl MqttX.Transport
  def getopts(socket, opts) do
    :inet.getopts(socket, opts)
  end

  @impl MqttX.Transport
  def setopts(socket, opts) do
    :inet.setopts(socket, opts)
  end

  # Ranch protocol module
  defmodule Protocol do
    @moduledoc false

    use GenServer

    alias MqttX.Packet.Codec
    alias MqttX.Telemetry

    require Logger

    @behaviour :ranch_protocol

    @impl :ranch_protocol
    def start_link(ref, transport, opts) do
      GenServer.start_link(__MODULE__, {ref, transport, opts})
    end

    @impl GenServer
    def init({ref, transport, opts}) do
      {:ok, socket} = :ranch.handshake(ref)
      transport.setopts(socket, [{:active, :once}])

      rate_limiter = opts.rate_limiter

      # Check connection rate limit
      if rate_limiter do
        case MqttX.Server.RateLimiter.allow_connection?(rate_limiter) do
          :ok ->
            :ok

          {:error, :rate_limited} ->
            transport.close(socket)
            {:stop, :normal}
        end
      end
      |> case do
        {:stop, :normal} ->
          {:stop, :normal}

        _ ->
          handler = opts.handler
          handler_opts = opts.handler_opts
          retained_table = opts.retained_table

          state = %{
            socket: socket,
            transport: transport,
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
            handler_has_handle_info: function_exported?(handler, :handle_info, 2),
            handler_has_handle_puback: function_exported?(handler, :handle_puback, 3),
            handler_has_handle_auth: function_exported?(handler, :handle_auth, 3),
            handler_has_handle_session_expired:
              function_exported?(handler, :handle_session_expired, 2)
          }

          {:ok, state}
      end
    end

    @impl GenServer
    def handle_info({:tcp, socket, data}, %{socket: socket, transport: transport} = state) do
      buffer =
        case state.buffer do
          <<>> -> data
          buf -> buf <> data
        end

      state = %{state | buffer: buffer}

      case process_buffer(state) do
        {:ok, new_state} ->
          transport.setopts(socket, [{:active, :once}])
          {:noreply, new_state}

        {:close, _reason, new_state} ->
          {:stop, :normal, new_state}

        {:error, _reason, new_state} ->
          {:stop, :normal, new_state}
      end
    end

    def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
      Logger.debug("[MqttX.Transport.Ranch] Connection closed")

      # Emit telemetry for ungraceful disconnect
      if state.connected and not state.graceful_disconnect do
        Telemetry.server_client_disconnect(%{client_id: state.client_id, reason: :closed})
      end

      # Publish will message if connection was not gracefully closed
      if state.connected and not is_nil(state.will_message) and not state.graceful_disconnect do
        maybe_publish_will(state)
      end

      if state.connected and state.handler do
        state.handler.handle_disconnect(:closed, state.handler_state)
      end

      if state.connected and not state.graceful_disconnect do
        maybe_start_session_expiry(state)
      end

      {:stop, :normal, state}
    end

    def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
      Logger.warning("[MqttX.Transport.Ranch] TCP error: #{inspect(reason)}")

      # Publish will message on error
      if state.connected and not is_nil(state.will_message) and not state.graceful_disconnect do
        maybe_publish_will(state)
      end

      if state.connected and state.handler do
        state.handler.handle_disconnect({:error, reason}, state.handler_state)
      end

      if state.connected do
        maybe_start_session_expiry(state)
      end

      {:stop, :normal, state}
    end

    # Handle keepalive timeout
    def handle_info(:keepalive_timeout, state) do
      Logger.debug("[MqttX.Transport.Ranch] Keepalive timeout for #{state.client_id}")

      # Publish will message on keepalive timeout (ungraceful)
      if state.connected and not is_nil(state.will_message) do
        maybe_publish_will(state)
      end

      if state.connected and state.handler do
        state.handler.handle_disconnect(:keepalive_timeout, state.handler_state)
      end

      {:stop, :normal, state}
    end

    # Handle server-initiated disconnect
    def handle_info({:server_disconnect, reason_code, properties}, state) do
      send_disconnect(state, reason_code, properties)

      if state.connected and state.handler do
        state.handler.handle_disconnect({:server_disconnect, reason_code}, state.handler_state)
      end

      {:stop, :normal, %{state | graceful_disconnect: true}}
    end

    # Handle custom messages (PubSub, etc.) - forward to user's handler
    def handle_info(message, state) do
      if state.connected and state.handler_has_handle_info do
        case state.handler.handle_info(message, state.handler_state) do
          {:ok, new_handler_state} ->
            {:noreply, %{state | handler_state: new_handler_state}}

          {:publish, topic, payload, new_handler_state} ->
            send_publish(state, topic, payload, %{qos: 0, retain: false})
            {:noreply, %{state | handler_state: new_handler_state}}

          {:publish, topic, payload, opts, new_handler_state} ->
            send_publish(state, topic, payload, opts)
            {:noreply, %{state | handler_state: new_handler_state}}

          {:disconnect, reason_code, new_handler_state} ->
            send_disconnect(state, reason_code, %{})
            state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:stop, :normal,
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}

          {:disconnect, reason_code, properties, new_handler_state} ->
            send_disconnect(state, reason_code, properties)
            state.handler.handle_disconnect({:server_disconnect, reason_code}, new_handler_state)

            {:stop, :normal,
             %{state | handler_state: new_handler_state, graceful_disconnect: true}}

          {:stop, _reason, new_handler_state} ->
            {:stop, :normal, %{state | handler_state: new_handler_state}}
        end
      else
        {:noreply, state}
      end
    end

    # Process incoming data buffer
    defp process_buffer(state) do
      version = state.protocol_version || 4

      case Codec.decode(version, state.buffer) do
        {:ok, {packet, rest}} ->
          case handle_packet(packet, state) do
            {:ok, new_state} ->
              process_buffer(%{reset_keepalive_timer(new_state) | buffer: rest})

            {:close, reason, new_state} ->
              {:close, reason, %{new_state | buffer: rest}}
          end

        {:error, :incomplete} ->
          {:ok, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end

    # Handle CONNECT
    defp handle_packet(%{type: :connect} = packet, state) do
      handler = state.handler
      protocol_version = packet.protocol_version

      # Emit telemetry for connect start
      telemetry_meta = %{client_id: packet.client_id, protocol_version: protocol_version}
      start_time = System.monotonic_time()
      Telemetry.server_client_connect_start(telemetry_meta)

      credentials = %{
        username: packet.username,
        password: packet.password
      }

      case handler.handle_connect(packet.client_id, credentials, state.handler_state) do
        {:ok, new_handler_state} ->
          # Emit telemetry for connect success
          duration = System.monotonic_time() - start_time
          Telemetry.server_client_connect_stop(duration, telemetry_meta)

          connack = %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          }

          send_packet(state, connack, protocol_version)

          # Extract will message if present
          will_message = extract_will_message(packet)

          # Extract keep_alive and session_expiry_interval
          keep_alive = Map.get(packet, :keep_alive, 0) || 0
          session_expiry_interval = get_in(packet, [:properties, :session_expiry_interval])

          new_state = %{
            state
            | protocol_version: protocol_version,
              client_id: packet.client_id,
              handler_state: new_handler_state,
              will_message: will_message,
              connected: true,
              keep_alive: keep_alive,
              session_expiry_interval: session_expiry_interval
          }

          {:ok, start_keepalive_timer(new_state)}

        {:error, reason_code, new_handler_state} ->
          # Emit telemetry for connect failure
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

    # Handle PUBLISH
    defp handle_packet(%{type: :publish} = packet, state) do
      # Check message rate limit
      if state.rate_limiter && state.client_id do
        case MqttX.Server.RateLimiter.allow_message?(state.rate_limiter, state.client_id) do
          :ok ->
            :ok

          {:error, :rate_limited} ->
            throw({:message_rate_limited, packet, state})
        end
      end

      handler = state.handler

      # Emit telemetry for publish received
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

      # Handle retained message storage
      if packet.retain do
        handle_retained_message(
          packet.topic,
          packet.payload,
          packet.qos,
          packet.properties,
          state.retained_table
        )
      end

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
    catch
      {:message_rate_limited, rate_limited_packet, current_state} ->
        # For QoS 1+: send PUBACK with reason_code 0x96 (message_rate_too_high)
        if rate_limited_packet.qos >= 1 do
          puback = %{
            type: :puback,
            packet_id: rate_limited_packet.packet_id,
            reason_code: 0x96,
            properties: %{}
          }

          send_packet(current_state, puback, current_state.protocol_version)
        end

        # For QoS 0: silently drop (per MQTT spec)
        {:ok, current_state}
    end

    # Handle SUBSCRIBE
    defp handle_packet(%{type: :subscribe} = packet, state) do
      handler = state.handler

      # Emit telemetry for subscribe
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

          # Deliver retained messages for subscribed topics
          deliver_retained_messages(state, packet.topics)

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

    # Handle DISCONNECT
    defp handle_packet(%{type: :disconnect}, state) do
      state = cancel_keepalive_timer(state)

      # Emit telemetry for disconnect
      Telemetry.server_client_disconnect(%{client_id: state.client_id, reason: :normal})

      if state.handler do
        state.handler.handle_disconnect(:normal, state.handler_state)
      end

      maybe_start_session_expiry(state)

      # Mark as graceful disconnect - don't publish will message
      {:close, :disconnect, %{state | graceful_disconnect: true}}
    end

    # Handle PUBACK
    defp handle_packet(%{type: :puback} = packet, state) do
      if state.handler_has_handle_puback do
        case state.handler.handle_puback(packet.packet_id, state.handler_state) do
          {:ok, new_handler_state} ->
            {:ok, %{state | handler_state: new_handler_state}}
        end
      else
        {:ok, state}
      end
    end

    # Handle AUTH (MQTT 5.0 enhanced authentication)
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

    # Catch-all
    defp handle_packet(packet, state) do
      Logger.debug("[MqttX.Transport.Ranch] Unhandled packet: #{inspect(packet.type)}")
      {:ok, state}
    end

    defp send_packet(state, packet, version) do
      case Codec.encode_iodata(version || 4, packet) do
        {:ok, data} ->
          state.transport.send(state.socket, data)

        {:error, reason} ->
          Logger.warning("[MqttX.Transport.Ranch] Failed to encode packet: #{inspect(reason)}")
          {:error, reason}
      end
    end

    # Keepalive timer helpers
    defp start_keepalive_timer(%{keep_alive: 0} = state), do: state

    defp start_keepalive_timer(%{keep_alive: keep_alive} = state) do
      # MQTT spec: 1.5x keep_alive seconds
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
      packet = %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: Map.get(opts, :qos, 0),
        retain: Map.get(opts, :retain, false),
        dup: false,
        packet_id: if(Map.get(opts, :qos, 0) > 0, do: :rand.uniform(65535), else: nil),
        properties: %{}
      }

      send_packet(state, packet, state.protocol_version || 4)
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
        properties: will_props
      }
    end

    defp extract_will_message(_), do: nil

    # Maybe publish will message, respecting will_delay_interval
    defp maybe_publish_will(%{will_message: nil}), do: :ok

    defp maybe_publish_will(%{will_message: %{delay_interval: delay}} = state) when delay > 0 do
      # Capture state snapshot for delayed publish (process may be dying)
      state_snapshot = Map.take(state, [:will_message, :handler, :handler_state, :retained_table])

      Task.start(fn ->
        Process.sleep(delay * 1000)
        do_publish_will(state_snapshot)
      end)

      :ok
    end

    defp maybe_publish_will(state) do
      do_publish_will(state)
    end

    # Publish will message to handler (no socket dependency)
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

      # Handle retained will message
      if will.retain do
        handle_retained_message(
          will.topic,
          will.payload,
          will.qos,
          will_props,
          state.retained_table
        )
      end

      # Let the handler distribute the will message to subscribers
      state.handler.handle_publish(will.topic, will.payload, opts, state.handler_state)
    end

    # Handle retained message storage
    defp handle_retained_message(topic, <<>>, _qos, _properties, table) do
      # Empty payload means delete retained message
      topic_key = normalize_topic_key(topic)
      :ets.delete(table, topic_key)
      :ok
    end

    defp handle_retained_message(topic, payload, qos, properties, table) do
      # Store the retained message with timestamp, expiry interval, and normalized topic list
      topic_key = normalize_topic_key(topic)
      normalized_list = MqttX.Topic.normalize(topic_key)
      timestamp = System.system_time(:second)
      expiry_interval = Map.get(properties || %{}, :message_expiry_interval)
      :ets.insert(table, {topic_key, normalized_list, payload, qos, timestamp, expiry_interval})
      :ok
    end

    # Normalize topic to a consistent key format
    defp normalize_topic_key(topic) when is_list(topic), do: Enum.join(topic, "/")
    defp normalize_topic_key(topic) when is_binary(topic), do: topic

    # Deliver retained messages matching subscribed topics
    defp deliver_retained_messages(state, topics) do
      now = System.system_time(:second)

      # Pre-normalize all subscription filters once
      normalized_subs =
        Enum.map(topics, fn sub ->
          filter = get_topic_filter(sub)
          normalized = MqttX.Topic.normalize(filter)
          {sub, normalized}
        end)

      # Partition subscriptions into exact (no wildcards) and wildcard
      {exact_subs, wildcard_subs} =
        Enum.split_with(normalized_subs, fn {_sub, normalized} ->
          not Enum.any?(normalized, fn seg -> seg == :single_level or seg == :multi_level end)
        end)

      expired_keys = []

      # For exact subscriptions, use ETS lookup (O(1) per topic)
      expired_keys =
        Enum.reduce(exact_subs, expired_keys, fn {sub, _normalized}, exp_acc ->
          topic_key = get_topic_filter(sub)

          topic_key =
            if is_list(topic_key), do: Enum.join(topic_key, "/"), else: to_string(topic_key)

          case :ets.lookup(state.retained_table, topic_key) do
            [{^topic_key, _norm_list, payload, qos, timestamp, expiry_interval}] ->
              if expired?(timestamp, expiry_interval, now) do
                [topic_key | exp_acc]
              else
                send_retained(
                  state,
                  topic_key,
                  payload,
                  qos,
                  timestamp,
                  expiry_interval,
                  sub,
                  now
                )

                exp_acc
              end

            [{^topic_key, payload, qos, timestamp, expiry_interval}] ->
              if expired?(timestamp, expiry_interval, now) do
                [topic_key | exp_acc]
              else
                send_retained(
                  state,
                  topic_key,
                  payload,
                  qos,
                  timestamp,
                  expiry_interval,
                  sub,
                  now
                )

                exp_acc
              end

            [{^topic_key, payload, qos}] ->
              send_retained(state, topic_key, payload, qos, nil, nil, sub, now)
              exp_acc

            [] ->
              exp_acc
          end
        end)

      # For wildcard subscriptions, scan the table
      expired_keys =
        if wildcard_subs == [] do
          expired_keys
        else
          :ets.foldl(
            fn entry, expired_acc ->
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
                [retained_topic | expired_acc]
              else
                Enum.each(wildcard_subs, fn {sub, sub_normalized} ->
                  if MqttX.Topic.matches?(sub_normalized, normalized_topic) do
                    send_retained(
                      state,
                      retained_topic,
                      payload,
                      qos,
                      timestamp,
                      expiry_interval,
                      sub,
                      now
                    )
                  end
                end)

                expired_acc
              end
            end,
            expired_keys,
            state.retained_table
          )
        end

      # Clean up expired messages
      Enum.each(expired_keys, fn key -> :ets.delete(state.retained_table, key) end)
    end

    defp expired?(nil, _, _now), do: false
    defp expired?(_, nil, _now), do: false
    defp expired?(ts, exp, now), do: now - ts > exp

    defp send_retained(state, topic, payload, qos, timestamp, expiry_interval, sub, now) do
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

      packet = %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: effective_qos,
        retain: true,
        dup: false,
        packet_id: if(effective_qos > 0, do: :rand.uniform(65535), else: nil),
        properties: properties
      }

      send_packet(state, packet, state.protocol_version)
    end

    # Extract topic filter from subscription
    defp get_topic_filter(%{topic: topic}), do: topic
    defp get_topic_filter(topic) when is_binary(topic), do: topic
    defp get_topic_filter(topic) when is_list(topic), do: Enum.join(topic, "/")
  end
end
