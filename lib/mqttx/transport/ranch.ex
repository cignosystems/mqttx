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

    alias MqttX.Transport.Handler, as: Proto

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

      send_fn = fn data -> transport.send(socket, data) end

      case Proto.init(
             opts.handler,
             opts.handler_opts,
             opts.retained_table,
             opts.rate_limiter,
             send_fn
           ) do
        {:ok, proto} ->
          {:ok, %{proto: proto, socket: socket, transport: transport}}

        {:error, :rate_limited} ->
          transport.close(socket)
          {:stop, :normal}
      end
    end

    @impl GenServer
    def handle_info({:tcp, _sock, data}, state) do
      case Proto.handle_data(data, state.proto) do
        {:ok, p} ->
          state.transport.setopts(state.socket, [{:active, :once}])
          {:noreply, %{state | proto: p}}

        {:close, _, p} ->
          {:stop, :normal, %{state | proto: p}}

        {:error, _, p} ->
          {:stop, :normal, %{state | proto: p}}
      end
    end

    def handle_info({:tcp_closed, _}, state) do
      {:shutdown, p} = Proto.handle_close(state.proto)
      {:stop, :normal, %{state | proto: p}}
    end

    def handle_info({:tcp_error, _, reason}, state) do
      {:shutdown, p} = Proto.handle_error(reason, state.proto)
      {:stop, :normal, %{state | proto: p}}
    end

    def handle_info(msg, state) do
      case Proto.handle_info(msg, state.proto) do
        {:noreply, p} -> {:noreply, %{state | proto: p}}
        {:stop, r, p} -> {:stop, r, %{state | proto: p}}
      end
    end
  end
end
