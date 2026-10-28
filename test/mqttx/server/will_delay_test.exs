defmodule MqttX.Server.WillDelayTest do
  @moduledoc """
  The shared Will Delay server: a session that ends (Clean Start 1) gets its
  Will published at once with `fire/1`, and one client's raising handler
  does not lose the other clients' pending Wills.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MqttX.Server.WillDelay

  defmodule Recorder do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_id, _credentials, state), do: {:ok, state}

    def handle_publish(["boom"], _payload, _opts, _state), do: raise("boom")

    def handle_publish(topic, payload, _opts, %{pid: pid} = state) do
      send(pid, {:will, topic, payload})
      {:ok, state}
    end

    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp ctx do
    %{
      retained_table: MqttX.Server.RetainedStore.new_table(),
      listener: nil,
      handler: Recorder,
      handler_state: %{pid: self()},
      max_retained_messages: nil
    }
  end

  defp will(topic), do: %{topic: topic, payload: "gone", qos: 0, retain: false, properties: %{}}

  test "fire/1 publishes a pending Will now and forgets it" do
    scope = {:will_delay_test, make_ref()}
    :ok = WillDelay.schedule(scope, will("w/now"), 60_000, ctx())
    :ok = WillDelay.fire(scope)
    assert_receive {:will, "w/now", "gone"}, 1_000
    # Nothing left to fire
    :ok = WillDelay.fire(scope)
    refute_receive {:will, "w/now", _}, 200
  end

  test "a raising handle_publish loses only that Will" do
    boom = {:will_delay_test, make_ref()}
    other = {:will_delay_test, make_ref()}
    :ok = WillDelay.schedule(boom, will("boom"), 10, ctx())
    :ok = WillDelay.schedule(other, will("w/other"), 100, ctx())

    capture_log(fn ->
      assert_receive {:will, "w/other", "gone"}, 2_000
    end)

    assert Process.alive?(Process.whereis(WillDelay))
  end
end
