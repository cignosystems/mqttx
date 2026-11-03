defmodule MqttX.Client.SendTimeoutTest do
  @moduledoc """
  A broker that accepts the connection and then stops reading fills the send
  buffer and blocks the write. The client must not stay stuck in it: past
  `:send_timeout` the socket closes, the handler hears of it, and the process
  answers and reconnects.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Test.ForwardingHandler

  @fixtures Path.expand("../../fixtures/tls", __DIR__)
  @connack <<0x20, 2, 0, 0>>
  @payload :binary.copy(<<0>>, 1_000_000)

  # Answers each CONNECT with a CONNACK and never reads again
  defp stalled_broker(:tcp) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, recbuf: 4096, backlog: 8])

    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        accept_tcp(listen, test)
      end)

    {port, pid}
  end

  defp stalled_broker(:ssl) do
    {:ok, listen} =
      :ssl.listen(0,
        mode: :binary,
        active: false,
        reuseaddr: true,
        recbuf: 4096,
        certfile: Path.join(@fixtures, "server.pem"),
        keyfile: Path.join(@fixtures, "server-key.pem")
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    test = self()
    pid = spawn_link(fn -> accept_ssl(listen, test) end)
    {port, pid}
  end

  defp accept_tcp(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, _connect} = :gen_tcp.recv(socket, 0)
    :ok = :gen_tcp.send(socket, @connack)
    send(test, :accepted)
    accept_tcp(listen, test)
  end

  defp accept_ssl(listen, test) do
    {:ok, transport} = :ssl.transport_accept(listen)
    {:ok, socket} = :ssl.handshake(transport)
    {:ok, _connect} = :ssl.recv(socket, 0)
    :ok = :ssl.send(socket, @connack)
    send(test, :accepted)
    accept_ssl(listen, test)
  end

  # Publishes from its own process, since a blocked client outlasts a call
  defp flood(client) do
    spawn(fn -> flood_loop(client) end)
  end

  defp flood_loop(client) do
    try do
      MqttX.Client.publish(client, "a/b", @payload, qos: 0)
    catch
      :exit, _ -> :ok
    end

    flood_loop(client)
  end

  defp assert_recovers(opts) do
    capture_log(fn ->
      {:ok, client} =
        MqttX.Client.connect(
          [
            client_id: "st-#{System.unique_integer([:positive])}",
            host: "localhost",
            send_timeout: 500,
            keepalive: 0,
            handler: ForwardingHandler,
            handler_state: %{pid: self()}
          ] ++ opts
        )

      assert_receive :accepted, 5_000
      assert_receive {:mqtt_event, :connected, _}, 5_000

      flooder = flood(client)

      assert_receive {:mqtt_event, :disconnected, reason}, 15_000
      send(self(), {:reason, reason})
      Process.exit(flooder, :kill)

      # Answers again, and reconnects by itself
      assert_receive :accepted, 15_000
      assert :sys.get_state(client, 5_000)
      GenServer.stop(client, :normal, 5_000)
    end)

    assert_received {:reason, reason}
    assert reason in [:closed, {:error, :timeout}, {:error, :closed}]
  end

  test "over TCP" do
    {port, _broker} = stalled_broker(:tcp)
    assert_recovers(port: port, transport: :tcp)
  end

  test "over TLS" do
    {port, _broker} = stalled_broker(:ssl)

    assert_recovers(
      port: port,
      transport: :ssl,
      ssl_opts: [cacertfile: Path.join(@fixtures, "ca.pem")]
    )
  end

  test "the deadline is applied to the socket" do
    {port, _broker} = stalled_broker(:tcp)

    capture_log(fn ->
      {:ok, client} =
        MqttX.Client.connect(
          client_id: "st-opts",
          host: "localhost",
          port: port,
          send_timeout: 1234,
          await_connect: true,
          handler: ForwardingHandler,
          handler_state: %{pid: self()}
        )

      %{socket: socket} = :sys.get_state(client)

      assert {:ok, [send_timeout: 1234, send_timeout_close: true]} =
               :inet.getopts(socket, [:send_timeout, :send_timeout_close])

      GenServer.stop(client)
    end)
  end
end
