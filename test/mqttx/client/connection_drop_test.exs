defmodule MqttX.Client.ConnectionDropTest do
  @moduledoc """
  Callers blocked in `subscribe/3` are waiting for a SUBACK. When the connection
  drops that SUBACK will never come, so they must get `{:error, :not_connected}`
  at once rather than a call timeout — and a caller that gives up first must not
  leave a stale entry behind.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  setup do
    broker = FakeBroker.start()

    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: "drop-#{System.unique_integer([:positive])}",
        protocol_version: 5,
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
    {:ok, broker: broker, client: client}
  end

  test "a subscribe waiting for SUBACK fails fast when the connection drops",
       %{broker: broker, client: client} do
    task = Task.async(fn -> Connection.subscribe(client, "a/b", qos: 1) end)

    assert_receive {:broker, :packet, %{type: :subscribe}}, 2_000
    assert map_size(:sys.get_state(client).pending_subs) == 1

    # The broker goes away without answering
    FakeBroker.close(broker)

    assert {:error, :not_connected} = Task.await(task, 2_000)
    assert_receive {:mqtt_event, :disconnected, :closed}, 2_000
    assert :sys.get_state(client).pending_subs == %{}
  end

  test "a caller that dies before SUBACK is forgotten", %{client: client} do
    caller = spawn(fn -> Connection.subscribe(client, "a/b", qos: 1) end)

    assert_receive {:broker, :packet, %{type: :subscribe}}, 2_000
    assert map_size(:sys.get_state(client).pending_subs) == 1

    Process.exit(caller, :kill)

    # The monitor fires and the entry goes with it
    assert eventually(fn -> :sys.get_state(client).pending_subs == %{} end)
    assert Connection.connected?(client)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
