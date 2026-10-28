# Compiled only when the optional :thousand_island package is present; a
# project without it gets no warnings, and one that starts this transport
# anyway gets an undefined-module error naming it (see AGENTS.md)
if Code.ensure_loaded?(ThousandIsland) do
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
    - `:transport_module` - ThousandIsland transport module
      (`ThousandIsland.Transports.TCP` or `...SSL`)
    - `:transport_options` - SSL/TLS options when using the SSL transport,
      merged over a secure baseline (TLS 1.2/1.3, `secure_renegotiate`)
    - `:num_acceptors` - Number of acceptor processes (default: 100)
    - `:read_timeout` - ThousandIsland socket read timeout (default:
      `:infinity`). MQTT liveness is enforced by the protocol keepalive and
      `:max_idle_timeout` below; TI's own 60 s default would disconnect
      spec-compliant clients whose Keep Alive exceeds it.
    - `:name` - The handle `MqttX.Server.deliver/4` finds this listener by
      (default: the port number)
    - `:rate_limit` - Options for `MqttX.Server.RateLimiter`: `:max_connections`
      (all peers), `:max_connections_per_ip`, `:max_messages`, `:interval`
      (default: none)

    Everything below is passed through `transport_opts` to the protocol handler
    and applies to all adapters:

    - `:max_packet_size` - Reject packets whose declared size exceeds this,
      before the body is buffered (default: 1 MiB, `:infinity` disables)
    - `:max_idle_timeout` - Close a socket idle for this long regardless of the
      negotiated Keep Alive, which does not apply when a client connects with
      `keep_alive: 0` (default: 900_000 ms, `:infinity` disables)
    - `:connect_timeout` - Close a socket that has not completed CONNECT within
      this window (default: 10_000 ms, `:infinity` disables)
    - `:max_retained_messages` - Cap on distinct retained topics
      (default: 100_000, `:infinity` disables)
    - `:receive_maximum` - Inbound QoS > 0 flow-control window (default: 100;
      with the packet cap it bounds what a client can make the broker hold
      before PUBREL).
      A client that exceeds it is disconnected with 0x93 (§4.9)
    - `:max_outbound_queue` - Cap on publishes queued per session: QoS > 0
      publishes waiting for the client's Receive Maximum window, and what
      `MqttX.Server.deliver/3` holds for a session that is not connected;
      beyond it they are dropped with a warning (default: 10_000, `:infinity`
      disables)
    - `:max_session_expiry_interval` - Longest a session is kept after its
      connection ends, in seconds. A v5 client asking for more is told this
      value in CONNACK (§3.2.2.3.2); a 3.1.1 client with CleanSession 0 is
      kept exactly this long (default: 86_400, `:infinity` lifts the cap)
    - `:topic_alias_maximum` - Topic aliases the server accepts (default: 100)
    - `:outbound_topic_aliases` - Put Topic Aliases on the PUBLISHes sent to a
      v5 client that allows them, up to its Topic Alias Maximum (§3.3.2.3.4;
      default: `true`)
    - `:max_subscriptions` - Filters one session may hold (default: 10_000,
      `:infinity` lifts it); past it a new filter is refused with 0x97
    - `:max_sessions` - Sessions this listener keeps, connected or kept for
      their expiry (default: `:infinity`); a CONNECT needing a new one past
      it is refused with 0x97
    - `:server_keep_alive` - Cap on the Keep Alive, in seconds: a v5 client
      asking for more, or for none (0), is told this value in CONNACK
      (§3.2.2.3.14) and must use it; one asking for less keeps its own. A
      3.1.1 client cannot be told, so it is not capped
    - `:supported_versions` - Accepted protocol levels (default: `[3, 4, 5]`)
    - `:qos2_retry_interval` / `:qos2_max_retries` - Deprecated and ignored
      since 0.12.0: the broker never re-sends QoS 1/2 packets on a live
      connection (MQTT §4.4)
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

      # Secure TLS baseline — user options are merged over it (C1).
      transport_options =
        if transport_module == ThousandIsland.Transports.SSL,
          do: Keyword.merge(MqttX.Transport.tls_baseline(), transport_options),
          else: transport_options

      # Create ETS table for retained messages
      retained_table = create_retained_table(port)

      # Create rate limiter if configured
      rate_limiter =
        case Keyword.get(transport_opts, :rate_limit) do
          nil -> nil
          rate_limit_opts -> MqttX.Server.RateLimiter.new(rate_limit_opts)
        end

      handler_module = __MODULE__.Handler

      # Session State (§4.1) for every client of this listener, outliving their
      # connections; MqttX.Server.deliver/4 reaches the listener by :name or port
      listener = Keyword.get(transport_opts, :name, port)

      sessions =
        MqttX.Server.SessionStore.create(
          :"mqttx_#{port}",
          listener,
          Keyword.get(transport_opts, :session_backend)
        )

      MqttX.Server.register_listener(
        listener,
        MqttX.Server.Delivery.listener_context(
          handler_opts,
          sessions,
          retained_table,
          transport_opts
        )
      )

      handler_opts_full = %{
        handler: handler,
        handler_opts: handler_opts,
        transport_opts: transport_opts,
        retained_table: retained_table,
        rate_limiter: rate_limiter,
        sessions: sessions
      }

      thousand_island_opts = [
        port: port,
        handler_module: handler_module,
        handler_options: handler_opts_full,
        transport_module: transport_module,
        transport_options: [{:ip, ip} | transport_options],
        num_acceptors: num_acceptors,
        # ThousandIsland's default 60s read_timeout would kill compliant MQTT
        # clients whose keepalive exceeds ~40s. Liveness is enforced by the
        # protocol itself (keepalive timer + pre-CONNECT handshake deadline).
        read_timeout: Keyword.get(transport_opts, :read_timeout, :infinity)
      ]

      Logger.info("[MqttX.Transport.ThousandIsland] Starting on port #{port}")
      ThousandIsland.start_link(thousand_island_opts)
    end

    defp create_retained_table(port) do
      MqttX.Server.RetainedStore.create_table(:"mqttx_retained_#{port}")
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

      alias MqttX.Transport.Handler, as: Proto

      # After a close this side decided on (a DISCONNECT was just written):
      # shut down the write side, so the FIN follows the packet, then read and
      # drop what the client still sends until it closes or this long has
      # passed. A close with unread data is a TCP reset on Linux, which can
      # discard the DISCONNECT before the client reads it (#7). The protocol
      # handler's close work runs when the drain ends (handle_close, once).
      @drain_ms 100

      @impl ThousandIsland.Handler
      def handle_connection(socket, state) do
        send_fn = fn data -> ThousandIsland.Socket.send(socket, data) end

        case Proto.init(
               state.handler,
               state.handler_opts,
               state.retained_table,
               state.rate_limiter,
               send_fn,
               state.sessions,
               peer_ip(ThousandIsland.Socket.peername(socket))
             ) do
          {:ok, proto} -> {:continue, proto}
          {:error, :rate_limited} -> {:close, state}
        end
      end

      @impl ThousandIsland.Handler
      def handle_data(_data, _socket, %{draining: _} = state), do: {:continue, state}

      def handle_data(data, socket, state) do
        case Proto.handle_data(data, state) do
          {:ok, s} -> {:continue, s}
          {:close, _, s} -> {:continue, drain(socket, s)}
          {:error, _, s} -> {:continue, drain(socket, s)}
        end
      end

      @impl ThousandIsland.Handler
      def handle_close(_socket, state) do
        Proto.handle_close(state)
      end

      # A drain ended by a socket error or by Thousand Island's own read
      # timeout: a close this side chose, so the protocol's close work, not
      # its error path
      @impl ThousandIsland.Handler
      def handle_error(_reason, _socket, %{draining: _} = state), do: Proto.handle_close(state)
      def handle_error(reason, _socket, state), do: Proto.handle_error(reason, state)

      @impl ThousandIsland.Handler
      def handle_timeout(_socket, %{draining: _} = state), do: Proto.handle_close(state)
      def handle_timeout(_socket, state), do: Proto.handle_timeout(state)

      # Drained: Thousand Island calls handle_close and closes the socket
      @impl GenServer
      def handle_info({:mqttx_drained, ref}, {socket, %{draining: ref} = state}),
        do: {:stop, {:shutdown, :drained}, {socket, state}}

      # A new connection for the client is taking the session over: answered
      # now, not after the drain, so it neither waits out the takeover
      # deadline nor inherits an expiry timer this side would start later
      def handle_info(msg, {socket, %{draining: _} = state})
          when elem(msg, 0) == :session_takeover do
        {:stop, _reason, state} = Proto.handle_info(msg, state)
        {:noreply, {socket, state}}
      end

      # Deliveries meanwhile are dropped: the session has been ended
      def handle_info(_msg, {socket, %{draining: _} = state}), do: {:noreply, {socket, state}}

      def handle_info(msg, {socket, state}) do
        case Proto.handle_info(msg, state) do
          {:noreply, s} -> {:noreply, {socket, s}}
          {:stop, _reason, s} -> {:noreply, {socket, drain(socket, s)}}
        end
      end

      # Crash reports and :sys.get_status never show a password or raw bytes
      @impl GenServer
      def format_status(status) do
        status
        |> Map.update(:state, nil, fn
          {socket, %{} = proto} -> {socket, Proto.redact(proto)}
          other -> other
        end)
        |> Map.update(:message, nil, &Proto.redact_message/1)
      end

      defp peer_ip({:ok, {ip, _port}}), do: ip
      defp peer_ip(_other), do: nil

      defp drain(socket, state) do
        ThousandIsland.Socket.shutdown(socket, :write)
        ref = make_ref()
        Process.send_after(self(), {:mqttx_drained, ref}, @drain_ms)
        Map.put(state, :draining, ref)
      end
    end
  end
end
