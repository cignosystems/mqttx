defmodule MqttX.Client.AdvertisedLimitsTest do
  @moduledoc """
  A v5 CONNECT tells the broker what this side enforces on inbound traffic,
  unless the caller set it: the QoS > 0 window and the packet cap, so the
  broker never sends what the client would tear the connection down for.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # Started, not connected: port 1 refuses, and the properties are decided
  # at start
  defp properties(opts) do
    capture_log(fn ->
      {:ok, pid} =
        MqttX.Client.connect(
          [host: "127.0.0.1", port: 1, client_id: "limits-#{System.unique_integer()}"] ++ opts
        )

      send(self(), {:props, :sys.get_state(pid).connect_properties})
      GenServer.stop(pid)
    end)

    receive do
      {:props, props} -> props
    end
  end

  test "Receive Maximum 100 and the packet cap, by default" do
    assert %{receive_maximum: 100, maximum_packet_size: 1_048_576} =
             properties(protocol_version: 5)
  end

  test "the caller's values stand, and no cap is advertised for :infinity" do
    props =
      properties(
        protocol_version: 5,
        connect_properties: %{receive_maximum: 7},
        max_packet_size: :infinity
      )

    assert props.receive_maximum == 7
    refute Map.has_key?(props, :maximum_packet_size)
  end

  test "a 3.1.1 CONNECT carries no properties" do
    assert properties(protocol_version: 4) == %{}
  end
end
