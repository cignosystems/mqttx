defmodule MqttXTest do
  use ExUnit.Case

  test "returns version" do
    assert MqttX.version() == "0.1.0"
  end
end
