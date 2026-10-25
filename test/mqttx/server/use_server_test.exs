defmodule MqttX.Server.UseServerTest do
  @moduledoc """
  What `use MqttX.Server` says at compile time: `handle_connect/3` and
  `handle_connect/4` are alternatives, so a handler with either compiles
  silently and one with neither is warned.
  """
  # Capturing :stderr is global, so not alongside other tests
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp compile(name, handle_connect) do
    source = """
    defmodule #{name} do
      use MqttX.Server

      def init(_opts), do: %{}
      #{handle_connect}
      def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
      def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
      def handle_disconnect(_reason, _state), do: :ok
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(source) end)
  end

  test "a handler with handle_connect/4 alone compiles without a warning" do
    assert compile(
             "MqttX.UseServerTest.Four",
             "def handle_connect(_id, _credentials, _info, state), do: {:ok, state}"
           ) == ""
  end

  test "a handler with handle_connect/3 alone compiles without a warning" do
    assert compile(
             "MqttX.UseServerTest.Three",
             "def handle_connect(_id, _credentials, state), do: {:ok, state}"
           ) == ""
  end

  test "a handler with neither is warned" do
    output = compile("MqttX.UseServerTest.Neither", "")
    assert output =~ "neither handle_connect/4 nor handle_connect/3"
    assert output =~ "MqttX.UseServerTest.Neither"
  end
end
