if Code.ensure_loaded?(Bandit) and Code.ensure_loaded?(WebSockAdapter) do
  defmodule MqttX.Transport.WebSocket do
    @moduledoc """
    WebSocket transport adapter for MqttX.

    This adapter uses Bandit + WebSockAdapter to serve MQTT over WebSocket (RFC 6455).

    ## Usage

        MqttX.Server.start_link(MyHandler, handler_opts,
          transport: MqttX.Transport.WebSocket,
          port: 8083
        )

    ## Options

    - `:port` - Port to listen on (default: 8083)
    - `:ip` - IP address to bind to (default: `{0, 0, 0, 0}`)
    - `:path` - WebSocket path (default: `/mqtt`)
    """

    @behaviour MqttX.Transport

    require Logger

    @default_port 8083

    @impl MqttX.Transport
    def start_link(handler, handler_opts, transport_opts) do
      port = Keyword.get(transport_opts, :port, @default_port)
      ip = Keyword.get(transport_opts, :ip, {0, 0, 0, 0})

      retained_table = create_retained_table(port)

      rate_limiter =
        case Keyword.get(transport_opts, :rate_limit) do
          nil -> nil
          rate_limit_opts -> MqttX.Server.RateLimiter.new(rate_limit_opts)
        end

      plug_opts = %{
        handler: handler,
        handler_opts: handler_opts,
        retained_table: retained_table,
        rate_limiter: rate_limiter,
        path: Keyword.get(transport_opts, :path, "/mqtt")
      }

      bandit_opts = [
        plug: {__MODULE__.Plug, plug_opts},
        port: port,
        ip: ip,
        scheme: :http
      ]

      Logger.info("[MqttX.Transport.WebSocket] Starting on port #{port}")
      Bandit.start_link(bandit_opts)
    end

    defp create_retained_table(port) do
      table_name = :"mqttx_ws_retained_#{port}"

      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:named_table, :public, :set])

        _ref ->
          table_name
      end
    end

    @impl MqttX.Transport
    def send(_socket, _data), do: {:error, :not_supported}

    @impl MqttX.Transport
    def close(_socket), do: :ok

    @impl MqttX.Transport
    def peername(_socket), do: {:error, :not_supported}

    @impl MqttX.Transport
    def getopts(_socket, _opts), do: {:error, :not_supported}

    @impl MqttX.Transport
    def setopts(_socket, _opts), do: {:error, :not_supported}
  end

  defmodule MqttX.Transport.WebSocket.Plug do
    @moduledoc false

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      paths = [opts.path, "/"]
      paths = Enum.uniq(paths)

      if conn.request_path in paths do
        # Validate MQTT subprotocol
        subprotocols =
          Plug.Conn.get_req_header(conn, "sec-websocket-protocol")
          |> Enum.flat_map(&String.split(&1, ","))
          |> Enum.map(&String.trim/1)

        if "mqtt" in subprotocols do
          conn
          |> Plug.Conn.put_resp_header("sec-websocket-protocol", "mqtt")
          |> WebSockAdapter.upgrade(
            MqttX.Transport.WebSocket.Handler,
            %{
              handler: opts.handler,
              handler_opts: opts.handler_opts,
              retained_table: opts.retained_table,
              rate_limiter: opts.rate_limiter
            },
            []
          )
        else
          conn
          |> Plug.Conn.send_resp(400, "Missing mqtt subprotocol")
        end
      else
        conn
        |> Plug.Conn.send_resp(404, "Not found")
      end
    end
  end

  defmodule MqttX.Transport.WebSocket.Handler do
    @moduledoc false

    @behaviour WebSock

    alias MqttX.Transport.Handler, as: Proto

    @impl WebSock
    def init(opts) do
      send_fn = fn data -> send(self(), {:ws_send, {:binary, data}}) end

      case Proto.init(
             opts.handler,
             opts.handler_opts,
             opts.retained_table,
             opts.rate_limiter,
             send_fn
           ) do
        {:ok, proto} ->
          {:ok, proto}

        {:error, :rate_limited} ->
          {:stop, :normal, {1008, "Rate limited"}}
      end
    end

    @impl WebSock
    def handle_in({data, [opcode: :binary]}, state) do
      case Proto.handle_data(data, state) do
        {:ok, s} ->
          frames = flush_ws_sends()
          if frames == [], do: {:ok, s}, else: {:push, frames, s}

        {:close, _reason, s} ->
          frames = flush_ws_sends()
          if frames == [], do: {:stop, :normal, s}, else: {:stop, :normal, {1000, ""}, s}

        {:error, _reason, s} ->
          frames = flush_ws_sends()
          if frames == [], do: {:stop, :normal, s}, else: {:stop, :normal, {1011, ""}, s}
      end
    end

    def handle_in(_other, state) do
      {:ok, state}
    end

    @impl WebSock
    def handle_info({:ws_send, frame}, state) do
      {:push, [frame], state}
    end

    def handle_info(msg, state) do
      case Proto.handle_info(msg, state) do
        {:noreply, s} ->
          frames = flush_ws_sends()
          if frames == [], do: {:ok, s}, else: {:push, frames, s}

        {:stop, _reason, s} ->
          frames = flush_ws_sends()
          if frames == [], do: {:stop, :normal, s}, else: {:stop, :normal, {1000, ""}, s}
      end
    end

    @impl WebSock
    def terminate(_reason, state) do
      Proto.handle_close(state)
      :ok
    end

    defp flush_ws_sends(acc \\ []) do
      receive do
        {:ws_send, frame} -> flush_ws_sends([frame | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
