defmodule MqttX.Test.ForwardingHandler do
  @moduledoc """
  A client handler that forwards every event to the process in its state as
  `{:mqtt_event, event, data}`, so tests can `assert_receive` on them.
  """

  def handle_mqtt_event(event, data, %{pid: pid} = state) do
    send(pid, {:mqtt_event, event, data})
    state
  end
end
