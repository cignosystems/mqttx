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

    ref = make_ref()

    protocol_opts = %{
      handler: handler,
      handler_opts: handler_opts,
      transport_opts: transport_opts
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

      handler = opts.handler
      handler_opts = opts.handler_opts

      state = %{
        socket: socket,
        transport: transport,
        buffer: <<>>,
        protocol_version: nil,
        client_id: nil,
        handler: handler,
        handler_state: handler.init(handler_opts),
        connected: false
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_info({:tcp, socket, data}, %{socket: socket, transport: transport} = state) do
      state = %{state | buffer: state.buffer <> data}

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

      if state.connected and state.handler do
        state.handler.handle_disconnect(:closed, state.handler_state)
      end

      {:stop, :normal, state}
    end

    def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
      Logger.warning("[MqttX.Transport.Ranch] TCP error: #{inspect(reason)}")

      if state.connected and state.handler do
        state.handler.handle_disconnect({:error, reason}, state.handler_state)
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state) do
      {:noreply, state}
    end

    # Process incoming data buffer
    defp process_buffer(state) do
      version = state.protocol_version || 4

      case Codec.decode(version, state.buffer) do
        {:ok, {packet, rest}} ->
          case handle_packet(packet, state) do
            {:ok, new_state} ->
              process_buffer(%{new_state | buffer: rest})

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

      credentials = %{
        username: packet.username,
        password: packet.password
      }

      case handler.handle_connect(packet.client_id, credentials, state.handler_state) do
        {:ok, new_handler_state} ->
          connack = %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          }

          send_packet(state, connack, protocol_version)

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

          send_packet(state, connack, protocol_version)
          {:close, :auth_failed, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle PUBLISH
    defp handle_packet(%{type: :publish} = packet, state) do
      handler = state.handler

      opts = %{
        qos: packet.qos,
        retain: packet.retain,
        dup: packet.dup,
        packet_id: packet.packet_id,
        properties: packet.properties
      }

      case handler.handle_publish(packet.topic, packet.payload, opts, state.handler_state) do
        {:ok, new_handler_state} ->
          if packet.qos == 1 do
            puback = %{type: :puback, packet_id: packet.packet_id}
            send_packet(state, puback, state.protocol_version)
          end

          {:ok, %{state | handler_state: new_handler_state}}

        {:error, _reason, new_handler_state} ->
          {:ok, %{state | handler_state: new_handler_state}}
      end
    end

    # Handle SUBSCRIBE
    defp handle_packet(%{type: :subscribe} = packet, state) do
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

          send_packet(state, suback, state.protocol_version)
          {:ok, %{state | handler_state: new_handler_state}}
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
      if state.handler do
        state.handler.handle_disconnect(:normal, state.handler_state)
      end

      {:close, :disconnect, state}
    end

    # Handle PUBACK
    defp handle_packet(%{type: :puback} = packet, state) do
      if function_exported?(state.handler, :handle_puback, 3) do
        case state.handler.handle_puback(packet.packet_id, state.handler_state) do
          {:ok, new_handler_state} ->
            {:ok, %{state | handler_state: new_handler_state}}
        end
      else
        {:ok, state}
      end
    end

    # Catch-all
    defp handle_packet(packet, state) do
      Logger.debug("[MqttX.Transport.Ranch] Unhandled packet: #{inspect(packet.type)}")
      {:ok, state}
    end

    defp send_packet(state, packet, version) do
      case Codec.encode(version || 4, packet) do
        {:ok, data} ->
          state.transport.send(state.socket, data)

        {:error, reason} ->
          Logger.warning("[MqttX.Transport.Ranch] Failed to encode packet: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
