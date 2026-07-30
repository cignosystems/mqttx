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
  - `:ranch_transport` - Ranch transport (`:ranch_tcp` or `:ranch_ssl`, default: `:ranch_tcp`).
    Named `:transport` before v0.11.0, which collided with `MqttX.Server`'s
    own `:transport` option (the adapter module) — that collision made this
    adapter fail to start.
  - `:transport_options` - SSL/TLS options when using `:ranch_ssl`, merged
    over a secure baseline (TLS 1.2/1.3, `secure_renegotiate`)

  All protocol-level options (`:max_packet_size`, `:max_idle_timeout`,
  `:connect_timeout`, `:max_retained_messages`, `:rate_limit`, …) behave as
  documented in `MqttX.Transport.ThousandIsland`.
  """

  @behaviour MqttX.Transport

  require Logger

  @default_port 1883
  @default_num_acceptors 100

  @impl MqttX.Transport
  def start_link(handler, handler_opts, transport_opts) do
    port = Keyword.get(transport_opts, :port, @default_port)
    num_acceptors = Keyword.get(transport_opts, :num_acceptors, @default_num_acceptors)
    # `:transport` at the MqttX.Server level names *this adapter module* and
    # leaks through to us — only honor values that are actual ranch transports.
    ranch_transport =
      case Keyword.get(transport_opts, :ranch_transport) ||
             Keyword.get(transport_opts, :transport) do
        t when t in [:ranch_tcp, :ranch_ssl] -> t
        _ -> :ranch_tcp
      end

    ranch_opts = Keyword.get(transport_opts, :transport_options, [])

    # Secure TLS baseline — user options are merged over it (C1).
    ranch_opts =
      if ranch_transport == :ranch_ssl do
        Keyword.merge(
          [
            versions: [:"tlsv1.3", :"tlsv1.2"],
            secure_renegotiate: true,
            honor_cipher_order: true
          ],
          ranch_opts
        )
      else
        ranch_opts
      end

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

    # Ranch's connection supervisor calls start_link/3 synchronously and only
    # transfers the socket *after* it returns, while `:ranch.handshake/1`
    # blocks waiting for that transfer. Running the handshake inside
    # GenServer.init/1 therefore deadlocks the conns_sup on the first
    # connection — the documented ranch pattern is proc_lib + enter_loop.
    @impl :ranch_protocol
    def start_link(ref, transport, opts) do
      pid = :proc_lib.spawn_link(__MODULE__, :connection_init, [ref, transport, opts])
      {:ok, pid}
    end

    def connection_init(ref, transport, opts) do
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
          state = %{proto: proto, socket: socket, transport: transport}
          :gen_server.enter_loop(__MODULE__, [], state)

        {:error, :rate_limited} ->
          transport.close(socket)
          exit(:normal)
      end
    end

    @impl GenServer
    def init(arg) do
      # Never reached — connections enter via connection_init/3 + enter_loop.
      {:stop, {:not_supported, arg}}
    end

    @impl GenServer
    def handle_info({proto_tag, _sock, data}, state) when proto_tag in [:tcp, :ssl] do
      case Proto.handle_data(data, state.proto) do
        {:ok, p} ->
          state.transport.setopts(state.socket, [{:active, :once}])
          {:noreply, %{state | proto: p}}

        {:close, _reason, p} ->
          stop_with_close(%{state | proto: p})

        {:error, reason, p} ->
          stop_with_error(reason, %{state | proto: p})
      end
    end

    def handle_info({closed_tag, _}, state) when closed_tag in [:tcp_closed, :ssl_closed] do
      {:shutdown, p} = Proto.handle_close(state.proto)
      {:stop, :normal, %{state | proto: p}}
    end

    def handle_info({error_tag, _, reason}, state)
        when error_tag in [:tcp_error, :ssl_error] do
      {:shutdown, p} = Proto.handle_error(reason, state.proto)
      {:stop, :normal, %{state | proto: p}}
    end

    def handle_info(msg, state) do
      case Proto.handle_info(msg, state.proto) do
        {:noreply, p} -> {:noreply, %{state | proto: p}}
        {:stop, _r, p} -> stop_with_close(%{state | proto: p})
      end
    end

    # Route every locally-initiated stop through Proto.handle_close so wills,
    # handle_disconnect, and session expiry run (mirrors the ThousandIsland
    # adapter's terminate handling). handle_close is guarded internally by
    # the connected/graceful_disconnect flags.
    defp stop_with_close(state) do
      {:shutdown, p} = Proto.handle_close(state.proto)
      state.transport.close(state.socket)
      {:stop, :normal, %{state | proto: p}}
    end

    defp stop_with_error(reason, state) do
      {:shutdown, p} = Proto.handle_error(reason, state.proto)
      state.transport.close(state.socket)
      {:stop, :normal, %{state | proto: p}}
    end
  end
end
