defmodule MqttX.Client.KeepaliveTest do
  @moduledoc """
  The client's keepalive (§3.1.2.10): a PINGREQ every `keepalive` seconds, a
  PINGRESP clearing the 1.5 × keepalive deadline, and a missing PINGRESP tearing
  the socket down with `:pingresp_timeout` and reconnecting.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  @moduletag timeout: 30_000

  defp connect(broker, client_id) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: client_id,
        protocol_version: 5,
        # The smallest keepalive the protocol can express
        keepalive: 1,
        handler: ForwardingHandler,
        handler_state: %{pid: self()}
      )

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive {:mqtt_event, :connected, _}, 5_000
    client
  end

  test "an answered PINGREQ keeps the connection up" do
    broker = FakeBroker.start()
    client = connect(broker, "ka-answered")

    # Two keepalive rounds: by the end of the second we are past the deadline
    # the first PINGREQ armed, which only its PINGRESP can have cleared
    for _ <- 1..2 do
      assert_receive {:broker, :packet, %{type: :pingreq}}, 2_000
      FakeBroker.send(broker, %{type: :pingresp})
    end

    refute_receive {:mqtt_event, :disconnected, _}, 800
    assert Connection.connected?(client)
  end

  test "an unanswered PINGREQ tears the connection down and the client reconnects" do
    broker = FakeBroker.start()
    client = connect(broker, "ka-unanswered")

    assert_receive {:broker, :packet, %{type: :pingreq}}, 2_000
    # ...and the broker never answers

    log =
      capture_log(fn ->
        assert_receive {:mqtt_event, :disconnected, :pingresp_timeout}, 3_000
      end)

    assert log =~ "PINGRESP timeout"
    assert_receive {:broker, :closed}, 1_000
    refute Connection.connected?(client)

    # Reconnects on its own (backoff starts at 1 s)
    assert_receive {:broker, :connect, %{client_id: "ka-unanswered"}}, 5_000
    assert_receive {:mqtt_event, :connected, _}, 2_000
    assert Connection.connected?(client)
  end
end
