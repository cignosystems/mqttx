defmodule MqttX.Test.FakeBroker do
  @moduledoc """
  A scriptable stand-in for a broker, for client tests.

  `start/1` opens a listener and spawns an acceptor linked to the test process.
  For every connection it reads the CONNECT, reports it as
  `{:broker, :connect, packet}`, answers it (a success CONNACK unless told
  otherwise), then relays each packet the client sends as
  `{:broker, :packet, packet}` and reports `{:broker, :closed}` when the socket
  goes away — after which it accepts the next connection, so reconnects can be
  observed. Packets travel the other way with `send/2` and `send_raw/2`;
  `close/1` drops the current connection the way a crash or a network cut would.
  """

  alias MqttX.Packet.Codec

  defstruct [:pid, :port]

  @type t :: %__MODULE__{pid: pid(), port: :inet.port_number()}

  @success_connack %{type: :connack, session_present: false, reason_code: 0, properties: %{}}

  @doc """
  Start a broker on a free port.

  Options:

    * `:connack` — the reply to every CONNECT: a packet map (default: a
      success CONNACK), a binary sent verbatim, or `:none` to leave the
      handshake to the test, which then answers with `send/2` after it
      receives `{:broker, :connect, _}`.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    test_pid = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, nodelay: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, test_pid, opts) end)
    %__MODULE__{pid: pid, port: port}
  end

  @doc "Encode `packet` for the connected client's protocol version and send it."
  @spec send(t(), map()) :: :ok
  def send(%__MODULE__{pid: pid}, packet) when is_map(packet) do
    Kernel.send(pid, {:send_packet, packet})
    :ok
  end

  @doc "Write raw bytes to the client."
  @spec send_raw(t(), binary()) :: :ok
  def send_raw(%__MODULE__{pid: pid}, data) when is_binary(data) do
    Kernel.send(pid, {:send_raw, data})
    :ok
  end

  @doc "Close the current connection without a DISCONNECT."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    Kernel.send(pid, :close)
    :ok
  end

  defp accept_loop(listen, test_pid, opts) do
    {:ok, sock} = :gen_tcp.accept(listen)
    {connect, rest} = recv_connect(sock, <<>>)
    version = connect.protocol_version
    Kernel.send(test_pid, {:broker, :connect, connect})

    case Keyword.get(opts, :connack, @success_connack) do
      :none -> :ok
      data when is_binary(data) -> :gen_tcp.send(sock, data)
      packet -> write(sock, version, packet)
    end

    :ok = :inet.setopts(sock, active: :once)
    relay(sock, version, test_pid, rest)
    Kernel.send(test_pid, {:broker, :closed})
    accept_loop(listen, test_pid, opts)
  end

  # CONNECT carries its own protocol level, so decoding it as v5 is fine
  defp recv_connect(sock, buffer) do
    case Codec.decode(5, buffer) do
      {:ok, {%{type: :connect} = connect, rest}} ->
        {connect, rest}

      {:error, :incomplete} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_connect(sock, buffer <> data)
    end
  end

  # Hand over whatever is already complete, then wait on either side
  defp relay(sock, version, test_pid, buffer) do
    buffer = deliver(buffer, version, test_pid)

    receive do
      {:tcp, ^sock, data} ->
        :ok = :inet.setopts(sock, active: :once)
        relay(sock, version, test_pid, buffer <> data)

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _reason} ->
        :ok

      {:send_packet, packet} ->
        write(sock, version, packet)
        relay(sock, version, test_pid, buffer)

      {:send_raw, data} ->
        :gen_tcp.send(sock, data)
        relay(sock, version, test_pid, buffer)

      :close ->
        :gen_tcp.close(sock)
    end
  end

  defp deliver(buffer, version, test_pid) do
    case Codec.decode(version, buffer) do
      {:ok, {packet, rest}} ->
        Kernel.send(test_pid, {:broker, :packet, packet})
        deliver(rest, version, test_pid)

      {:error, :incomplete} ->
        buffer

      {:error, reason} ->
        Kernel.send(test_pid, {:broker, :decode_error, reason})
        <<>>
    end
  end

  defp write(sock, version, packet) do
    case Codec.encode(version, packet) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)

      {:error, reason} ->
        raise ArgumentError,
              "FakeBroker cannot encode #{inspect(packet)} for v#{version}: #{inspect(reason)}"
    end
  end
end
