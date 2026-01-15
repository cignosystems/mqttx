defmodule MqttXTest do
  use ExUnit.Case

  test "returns version" do
    version = MqttX.version()
    assert is_binary(version)
    assert version =~ ~r/^\d+\.\d+\.\d+$/
  end
end
