defmodule MqttX.Client.WebSocketHostHeaderTest do
  @moduledoc """
  The WebSocket upgrade's `Host` header carries the port unless it is the
  scheme's default (RFC 7230 §5.4): a virtual-hosted gateway routes on it.
  """
  use ExUnit.Case, async: true

  # Reads the request the client sends for the upgrade, and answers nothing
  defp request_for(port, transport) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, listen_port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, server} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(server, 0, 2_000)
      send(test, {:request, request})
      :gen_tcp.close(server)
    end)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, listen_port, [:binary, active: false])

    spawn_link(fn ->
      MqttX.Client.WebSocket.upgrade(socket, transport, "broker.example", port, "/mqtt")
    end)

    assert_receive {:request, request}, 2_000
    request
  end

  test "a port other than the scheme's default is in the Host header" do
    assert request_for(8083, :tcp) =~ "\r\nHost: broker.example:8083\r\n"
  end

  test "the scheme's default port is left out" do
    assert request_for(80, :tcp) =~ "\r\nHost: broker.example\r\n"
  end
end
