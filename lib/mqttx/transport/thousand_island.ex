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

    # Create ETS table for retained messages
    retained_table = create_retained_table(port)

    # Create rate limiter if configured
    rate_limiter =
      case Keyword.get(transport_opts, :rate_limit) do
        nil -> nil
        rate_limit_opts -> MqttX.Server.RateLimiter.new(rate_limit_opts)
      end

    handler_module = __MODULE__.Handler

    handler_opts_full = %{
      handler: handler,
      handler_opts: handler_opts,
      transport_opts: transport_opts,
      retained_table: retained_table,
      rate_limiter: rate_limiter
    }

    thousand_island_opts =
      [
        port: port,
        handler_module: handler_module,
        handler_options: handler_opts_full,
        transport_module: transport_module,
        transport_options: [{:ip, ip} | transport_options],
        num_acceptors: num_acceptors
      ] ++ read_timeout_opts(transport_opts)

    Logger.info("[MqttX.Transport.ThousandIsland] Starting on port #{port}")
    ThousandIsland.start_link(thousand_island_opts)
  end

  # Pass ThousandIsland's `read_timeout` through when the caller sets it. An MQTT
  # server governs connection liveness with its own keepalive timer (1.5x the
  # negotiated keep-alive); ThousandIsland's default socket read timeout (60s) is
  # independent of that and will close an idle-but-healthy connection whose
  # keep-alive is >= ~40s, racing the client's PINGREQ. Setting
  # `read_timeout: :infinity` lets the keepalive timer be authoritative. Omitted
  # when unset so ThousandIsland's default still applies (backward compatible).
  defp read_timeout_opts(transport_opts) do
    case Keyword.get(transport_opts, :read_timeout) do
      nil -> []
      read_timeout -> [read_timeout: read_timeout]
    end
  end

  defp create_retained_table(port) do
    table_name = :"mqttx_retained_#{port}"

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])

      _ref ->
        # Table already exists, return the name
        table_name
    end
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

    @impl ThousandIsland.Handler
    def handle_connection(socket, state) do
      send_fn = fn data -> ThousandIsland.Socket.send(socket, data) end

      case Proto.init(
             state.handler,
             state.handler_opts,
             state.retained_table,
             state.rate_limiter,
             send_fn
           ) do
        {:ok, proto} -> {:continue, proto}
        {:error, :rate_limited} -> {:close, state}
      end
    end

    @impl ThousandIsland.Handler
    def handle_data(data, _socket, state) do
      case Proto.handle_data(data, state) do
        {:ok, s} -> {:continue, s}
        {:close, _, s} -> {:close, s}
        {:error, _, s} -> {:close, s}
      end
    end

    @impl ThousandIsland.Handler
    def handle_close(_socket, state) do
      Proto.handle_close(state)
    end

    @impl ThousandIsland.Handler
    def handle_error(reason, _socket, state) do
      Proto.handle_error(reason, state)
    end

    @impl ThousandIsland.Handler
    def handle_timeout(_socket, state) do
      Proto.handle_timeout(state)
    end

    @impl GenServer
    def handle_info(msg, {socket, state}) do
      case Proto.handle_info(msg, state) do
        {:noreply, s} -> {:noreply, {socket, s}}
        {:stop, r, s} -> {:stop, r, {socket, s}}
      end
    end
  end
end
