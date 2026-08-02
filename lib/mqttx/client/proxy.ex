defmodule MqttX.Client.Proxy do
  @moduledoc false

  # HTTP CONNECT proxy tunneling (RFC 9110 §9.3.6) for the client transports.
  # Opens a TCP socket to the proxy, issues CONNECT for the target, and hands
  # back the raw socket once the proxy answers 200 — TLS and/or the WebSocket
  # upgrade are then layered over the tunnel by the caller, so certificate
  # verification and SNI target the broker, not the proxy.

  @max_response_bytes 8192

  @doc """
  Establish a tunnel to `host:port` through the proxy described by
  `proxy` (`[host:, port:, auth: {user, pass}]`).

  Returns `{:ok, socket}` (passive-mode `:gen_tcp` socket) or
  `{:error, {:proxy, reason}}` — reasons include `{:proxy_status, code}`
  for a non-200 answer, `:bad_proxy_response`, `:invalid_proxy_target`,
  and `:gen_tcp.connect/4` posix errors.
  """
  @spec connect(binary() | charlist(), :inet.port_number(), keyword(), timeout()) ::
          {:ok, :gen_tcp.socket()} | {:error, {:proxy, term()}}
  def connect(host, port, proxy, timeout) do
    proxy_host = to_charlist(Keyword.fetch!(proxy, :host))
    proxy_port = Keyword.get(proxy, :port, 3128)

    with :ok <- validate_target(host),
         {:ok, socket} <-
           :gen_tcp.connect(proxy_host, proxy_port, [:binary, active: false], timeout),
         :ok <- :gen_tcp.send(socket, connect_request(host, port, proxy)),
         :ok <- await_response(socket, <<>>, timeout) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, {:proxy, reason}}
    end
  end

  # The host is interpolated into the CONNECT request line and Host header —
  # CR/LF (or whitespace/NUL) would let a caller-supplied host inject
  # additional HTTP headers into the proxy request.
  defp validate_target(host) when is_binary(host) do
    if String.match?(host, ~r/[\r\n\0\s]/) do
      {:error, :invalid_proxy_target}
    else
      :ok
    end
  end

  defp validate_target(_host), do: :ok

  defp connect_request(host, port, proxy) do
    auth_header =
      case Keyword.get(proxy, :auth) do
        {user, pass} ->
          "Proxy-Authorization: Basic #{Base.encode64("#{user}:#{pass}")}\r\n"

        nil ->
          ""
      end

    "CONNECT #{host}:#{port} HTTP/1.1\r\n" <>
      "Host: #{host}:#{port}\r\n" <>
      auth_header <>
      "\r\n"
  end

  defp await_response(socket, buffer, timeout) when byte_size(buffer) < @max_response_bytes do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        buffer = buffer <> data

        if String.contains?(buffer, "\r\n\r\n") do
          case buffer do
            <<"HTTP/1.", _minor, " 200", _rest::binary>> ->
              :ok

            <<"HTTP/1.", _minor, " ", status::binary-size(3), _rest::binary>> ->
              # A hostile/broken proxy can send a non-numeric status —
              # Integer.parse avoids raising inside the connection GenServer
              # (which would kill the process and lose reconnect/backoff
              # state).
              case Integer.parse(status) do
                {code, _} -> {:error, {:proxy_status, code}}
                :error -> {:error, :bad_proxy_response}
              end

            _ ->
              {:error, :bad_proxy_response}
          end
        else
          await_response(socket, buffer, timeout)
        end

      {:error, _} = err ->
        err
    end
  end

  defp await_response(_socket, _buffer, _timeout), do: {:error, :bad_proxy_response}
end
