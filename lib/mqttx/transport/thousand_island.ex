defmodule MqttX.Transport.ThousandIsland do
  @moduledoc """
  ThousandIsland transport adapter for MqttX.

  This adapter uses ThousandIsland as the underlying TCP/TLS server.

  ## Usage

      MqttX.Server.start_link(MyHandler, handler_opts,
        transport: MqttX.Transport.ThousandIsland,
        port: 1883
      )

  ## Options

  - `:port` - Port to listen on (default: 1883)
  - `:ip` - IP address to bind to (default: `{0, 0, 0, 0}`)
  - `:transport_module` - ThousandIsland transport (`:tcp` or `:ssl`)
  - `:transport_options` - SSL/TLS options when using `:ssl`
  - `:num_acceptors` - Number of acceptor processes (default: 100)
  """

  @behaviour MqttX.Transport

  require Logger

  @default_port 1883
  @default_num_acceptors 100

  @impl MqttX.Transport
  def start_link(handler, handler_opts, transport_opts) do
    port = Keyword.get(transport_opts, :port, @default_port)
    ip = Keyword.get(transport_opts, :ip, {0, 0, 0, 0})
    num_acceptors = Keyword.get(transport_opts, :num_acceptors, @default_num_acceptors)

    transport_module =
      Keyword.get(transport_opts, :transport_module, ThousandIsland.Transports.TCP)

    transport_options = Keyword.get(transport_opts, :transport_options, [])

    handler_module = __MODULE__.Handler

    handler_opts_full = %{
      handler: handler,
      handler_opts: handler_opts,
      transport_opts: transport_opts
    }

    thousand_island_opts = [
      port: port,
      handler_module: handler_module,
      handler_options: handler_opts_full,
      transport_module: transport_module,
      transport_options: [{:ip, ip} | transport_options],
      num_acceptors: num_acceptors
    ]

    Logger.info("[MqttX.Transport.ThousandIsland] Starting on port #{port}")
    ThousandIsland.start_link(thousand_island_opts)
  end

  @impl MqttX.Transport
  def send(socket, data) do
    ThousandIsland.Socket.send(socket, data)
  end

  @impl MqttX.Transport
  def close(socket) do
    ThousandIsland.Socket.close(socket)
    :ok
  end

  @impl MqttX.Transport
  def peername(socket) do
    ThousandIsland.Socket.peername(socket)
  end

  @impl MqttX.Transport
  def getopts(socket, opts) do
    ThousandIsland.Socket.getopts(socket, opts)
  end

  @impl MqttX.Transport
  def setopts(socket, opts) do
    ThousandIsland.Socket.setopts(socket, opts)
  end

  # Inner handler module that implements ThousandIsland.Handler
  defmodule Handler do
    @moduledoc false

    use ThousandIsland.Handler

    alias MqttX.Packet.Codec

    require Logger

    @impl ThousandIsland.Handler
    def handle_connection(socket, state) do
      handler = state.handler
      handler_opts = state.handler_opts

      # Initialize protocol state
      protocol_state = %{
        socket: socket,
        buffer: <<>>,
        protocol_version: nil,
        client_id: nil,
        handler: handler,
        handler_state: handler.init(handler_opts),
        connected: false
      }

      {:continue, protocol_state}
    end

    @impl ThousandIsland.Handler
    def handle_data(data, socket, state) do
      buffer = state.buffer <> data

      case process_buffer(buffer, socket, state) do
        {:ok, new_state} ->
          {:continue, new_state}

        {:close, reason, new_state} ->
          Logger.debug("[MqttX.Transport] Closing connection: #{inspect(reason)}")
          {:close, new_state}

        {:error, reason, new_state} ->
          Logger.warning("[MqttX.Transport] Error: #{inspect(reason)}")
          {:close, new_state}
      end
    end

    @impl ThousandIsland.Handler
    def handle_close(_socket, state) do
      if state.connected and state.handler do
        state.handler.handle_disconnect(:closed, state.handler_state)
      end

      {:shutdown, state}
    end

    @impl ThousandIsland.Handler
    def handle_error(reason, _socket, state) do
      Logger.warning("[MqttX.Transport] Connection error: #{inspect(reason)}")

      if state.connected and state.handler do
        state.handler.handle_disconnect({:error, reason}, state.handler_state)
      end

      {:shutdown, state}
    end

    @impl ThousandIsland.Handler
    def handle_timeout(_socket, state) do
      Logger.debug("[MqttX.Transport] Connection timeout")

      if state.connected and state.handler do
        state.handler.handle_disconnect(:timeout, state.handler_state)
      end

      {:close, state}
    end

    # Handle custom messages (PubSub, etc.) - forward to user's handler
    @impl GenServer
    def handle_info(message, {socket, state}) do
      if state.connected and function_exported?(state.handler, :handle_info, 2) do
        case state.handler.handle_info(message, state.handler_state) do
          {:ok, new_handler_state} ->
            {:noreply, {socket, %{state | handler_state: new_handler_state}}}

          {:publish, topic, payload, new_handler_state} ->
            send_publish(socket, topic, payload, %{qos: 0, retain: false}, state.protocol_version)
            {:noreply, {socket, %{state | handler_state: new_handler_state}}}

          {:publish, topic, payload, opts, new_handler_state} ->
            send_publish(socket, topic, payload, opts, state.protocol_version)
            {:noreply, {socket, %{state | handler_state: new_handler_state}}}

          {:stop, _reason, new_handler_state} ->
            {:stop, :normal, {socket, %{state | handler_state: new_handler_state}}}
        end
      else
        {:noreply, {socket, state}}
      end
    end

    # Send PUBLISH packet to client
    defp send_publish(socket, topic, payload, opts, version) do
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
      send_packet(socket, packet, version || 4)
    end

    # Process incoming data buffer
    defp process_buffer(buffer, socket, state) do
      version = state.protocol_version || 4

      case Codec.decode(version, buffer) do
        {:ok, {packet, rest}} ->
          case handle_packet(packet, socket, state) do
            {:ok, new_state} ->
              process_buffer(rest, socket, %{new_state | buffer: rest})

            {:close, reason, new_state} ->
              {:close, reason, %{new_state | buffer: rest}}
          end

        {:error, :incomplete} ->
          {:ok, %{state | buffer: buffer}}

        {:error, reason} ->
          {:error, reason, state}
      end
    end

    # Handle CONNECT
    defp handle_packet(%{type: :connect} = packet, socket, state) do
      handler = state.handler
      protocol_version = packet.protocol_version

      credentials = %{
        username: packet.username,
        password: packet.password
      }

      case handler.handle_connect(packet.client_id, credentials, state.handler_state) do
        {:ok, new_handler_state} ->
          # Send CONNACK success
          connack = %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          }

          send_packet(socket, connack, protocol_version)

          new_state = %{
            state
            | protocol_version: protocol_version,
              client_id: packet.client_id,
              handler_state: new_handler_state,
              connected: true
          }

          {:ok, new_state}

        {:error, reason_code, new_handler_state} ->
          connack = %{
            type: :connack,
            session_present: false,
            reason_code: reason_code,
            properties: %{}
          }

          send_packet(socket, connack, protocol_version)
          {:close, :auth_failed, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle PUBLISH
    defp handle_packet(%{type: :publish} = packet, _socket, state) do
      handler = state.handler
      topic = packet.topic
      payload = packet.payload

      opts = %{
        qos: packet.qos,
        retain: packet.retain,
        dup: packet.dup,
        packet_id: packet.packet_id,
        properties: packet.properties
      }

      case handler.handle_publish(topic, payload, opts, state.handler_state) do
        {:ok, new_handler_state} ->
          # Send PUBACK for QoS 1
          if packet.qos == 1 do
            puback = %{type: :puback, packet_id: packet.packet_id}
            send_packet(state.socket, puback, state.protocol_version)
          end

          {:ok, %{state | handler_state: new_handler_state}}

        {:error, _reason, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle SUBSCRIBE
    defp handle_packet(%{type: :subscribe} = packet, socket, state) do
      handler = state.handler

      case handler.handle_subscribe(packet.topics, state.handler_state) do
        {:ok, granted_qos, new_handler_state} ->
          acks = Enum.map(granted_qos, fn qos -> {:ok, qos} end)

          suback = %{
            type: :suback,
            packet_id: packet.packet_id,
            acks: acks,
            properties: %{}
          }

          send_packet(socket, suback, state.protocol_version)
          {:ok, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle UNSUBSCRIBE
    defp handle_packet(%{type: :unsubscribe} = packet, socket, state) do
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

          send_packet(socket, unsuback, state.protocol_version)
          {:ok, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle PINGREQ
    defp handle_packet(%{type: :pingreq}, socket, state) do
      pingresp = %{type: :pingresp}
      send_packet(socket, pingresp, state.protocol_version)
      {:ok, state}
    end

    # Handle DISCONNECT
    defp handle_packet(%{type: :disconnect}, _socket, state) do
      if state.handler do
        state.handler.handle_disconnect(:normal, state.handler_state)
      end

      {:close, :disconnect, state}
    end

    # Handle PUBACK (for QoS 1 outgoing messages)
    defp handle_packet(%{type: :puback} = packet, _socket, state) do
      if function_exported?(state.handler, :handle_puback, 3) do
        case state.handler.handle_puback(packet.packet_id, state.handler_state) do
          {:ok, new_handler_state} ->
            {:ok, %{state | handler_state: new_handler_state}}
        end
      else
        {:ok, state}
      end
    end

    # Catch-all for other packets
    defp handle_packet(packet, _socket, state) do
      Logger.debug("[MqttX.Transport] Unhandled packet: #{inspect(packet.type)}")
      {:ok, state}
    end

    # Send packet helper
    defp send_packet(socket, packet, version) do
      case Codec.encode(version || 4, packet) do
        {:ok, data} ->
          ThousandIsland.Socket.send(socket, data)

        {:error, reason} ->
          Logger.warning("[MqttX.Transport] Failed to encode packet: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
