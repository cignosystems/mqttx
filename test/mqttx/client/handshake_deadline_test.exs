defmodule MqttX.Client.HandshakeDeadlineTest do
  @moduledoc """
  A server (or proxy) that answers the handshake one byte at a time cannot
  hold the client process: the WebSocket upgrade and the proxy CONNECT each
  have one deadline for the whole response, after which the process is
  free again (and retries with backoff).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # Accepts, then drips one byte every 200 ms for as long as the socket lives
  defp drip_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      drip(socket)
    end)

    port
  end

  defp drip(socket) do
    case :gen_tcp.send(socket, "H") do
      :ok ->
        Process.sleep(200)
        drip(socket)

      _ ->
        :ok
    end
  end

  # The process answers a sys call once the handshake has given up; one
  # stuck in it would not answer at all
  defp responsive_within(opts, limit_ms) do
    capture_log(fn ->
      {:ok, pid} =
        MqttX.Client.connect([host: "127.0.0.1", client_id: "deadline"] ++ opts)

      started = System.monotonic_time(:millisecond)
      state = :sys.get_state(pid, limit_ms)
      send(self(), {:answered, state.connected, System.monotonic_time(:millisecond) - started})
      GenServer.stop(pid)
    end)

    receive do
      {:answered, connected, elapsed} -> {connected, elapsed}
    end
  end

  test "a WebSocket upgrade that never completes gives up within its deadline" do
    port = drip_server()
    {connected, elapsed} = responsive_within([port: port, transport: :ws], 20_000)
    refute connected
    assert elapsed < 12_000
  end

  test "a proxy that never answers CONNECT gives up within its deadline" do
    port = drip_server()

    {connected, elapsed} =
      responsive_within([port: 1, proxy: [host: "127.0.0.1", port: port]], 20_000)

    refute connected
    assert elapsed < 12_000
  end
end
