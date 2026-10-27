defmodule MqttX.Client.BackoffResetTest do
  @moduledoc """
  A connection that falls right after its CONNACK does not start the backoff
  over: a broker that accepts and drops the client each time (or sends it a
  message it refuses on every delivery) gets slower retries, not a loop.
  """
  # Reads every "Reconnecting in" line logged while it runs, so not beside
  # other tests whose clients reconnect
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MqttX.Packet.Codec

  # Accepts every connection, answers the CONNECT and closes at once
  defp fickle_broker do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn -> accept_loop(listen) end)
    port
  end

  defp accept_loop(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)

    spawn(fn ->
      with {:ok, _connect} <- :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, connack} =
          Codec.encode(5, %{
            type: :connack,
            session_present: false,
            reason_code: 0,
            properties: %{}
          })

        :gen_tcp.send(socket, connack)
      end

      :gen_tcp.close(socket)
    end)

    accept_loop(listen)
  end

  test "retries slow down across connections that fall at once" do
    port = fickle_broker()

    log =
      capture_log(fn ->
        {:ok, client} =
          MqttX.Client.connect(
            host: "127.0.0.1",
            port: port,
            client_id: "fickle",
            protocol_version: 5
          )

        Process.sleep(4_500)
        GenServer.stop(client)
      end)

    delays =
      Regex.scan(~r/Reconnecting in (\d+)ms/, log)
      |> Enum.map(fn [_, ms] -> String.to_integer(ms) end)

    assert length(delays) >= 2
    [first, second | _] = delays
    # Doubling with jitter: the second is well above the first
    assert second > first * 1.5
  end
end
