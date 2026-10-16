defmodule MqttX.Client.SubscribeOptionsTest do
  @moduledoc """
  Option validation at the API edge, so a bad option comes back as an error
  instead of a malformed packet going out: SUBSCRIBE options (§3.8.3.1,
  MQTT-3.8.3-4) and the Will QoS in CONNECT (§3.1.2.6).
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defp stop(client) do
    GenServer.stop(client, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  describe "subscribe/3" do
    setup do
      broker = FakeBroker.start()

      {:ok, client} =
        Connection.start_link(
          host: "localhost",
          port: broker.port,
          client_id: "sub-opts-#{System.unique_integer([:positive])}",
          protocol_version: 5,
          handler: ForwardingHandler,
          handler_state: %{pid: self()}
        )

      on_exit(fn -> stop(client) end)

      assert_receive {:mqtt_event, :connected, _}, 5_000
      {:ok, broker: broker, client: client}
    end

    test "a QoS outside 0..2 is refused before anything is sent", %{client: client} do
      assert {:error, :invalid_qos} = Connection.subscribe(client, "a/b", qos: 3)
      assert {:error, :invalid_qos} = Connection.subscribe(client, "a/b", qos: -1)
      assert {:error, :invalid_qos} = MqttX.Client.subscribe(client, ["a/b", "c"], qos: 7)

      refute_receive {:broker, :packet, %{type: :subscribe}}, 200
    end

    test "a Retain Handling outside 0..2 is refused", %{client: client} do
      assert {:error, :invalid_retain_handling} =
               Connection.subscribe(client, "a/b", retain_handling: 3)

      refute_receive {:broker, :packet, %{type: :subscribe}}, 200
    end

    test "No Local on a shared subscription is refused (MQTT-3.8.3-4)", %{client: client} do
      assert {:error, :no_local_on_shared_subscription} =
               Connection.subscribe(client, "$share/g/sensors/#", no_local: true)

      # One shared filter in a list taints the whole call
      assert {:error, :no_local_on_shared_subscription} =
               Connection.subscribe(client, ["plain/#", "$share/g/sensors/#"], no_local: true)

      refute_receive {:broker, :packet, %{type: :subscribe}}, 200
    end

    test "No Local on an ordinary filter, and a shared filter without it, go through",
         %{broker: broker, client: client} do
      task = Task.async(fn -> Connection.subscribe(client, "plain/#", no_local: true) end)
      assert_receive {:broker, :packet, %{type: :subscribe, packet_id: id1, topics: [t1]}}, 2_000
      assert t1.no_local == true
      FakeBroker.send(broker, %{type: :suback, packet_id: id1, acks: [{:ok, 0}]})
      assert {:ok, [0]} = Task.await(task)

      task = Task.async(fn -> Connection.subscribe(client, "$share/g/sensors/#", qos: 1) end)
      assert_receive {:broker, :packet, %{type: :subscribe, packet_id: id2, topics: [t2]}}, 2_000
      assert t2.no_local == false
      FakeBroker.send(broker, %{type: :suback, packet_id: id2, acks: [{:ok, 1}]})
      assert {:ok, [1]} = Task.await(task)
    end

    test "option errors win over :not_connected" do
      # No broker at all: the option check runs in the caller, before the call
      quiet = FakeBroker.start(connack: :none)

      {:ok, client} =
        Connection.start_link(
          host: "localhost",
          port: quiet.port,
          client_id: "sub-opts-offline-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> stop(client) end)

      assert {:error, :invalid_qos} = Connection.subscribe(client, "a/b", qos: 3)
      assert {:error, :not_connected} = Connection.subscribe(client, "a/b", qos: 1)
    end
  end

  describe "will_qos" do
    test "outside 0..2 raises ArgumentError at start_link/1" do
      assert_raise ArgumentError, ~r/will_qos.*must be 0, 1 or 2/, fn ->
        Connection.start_link(
          host: "localhost",
          port: 1,
          client_id: "will-qos-bad",
          will_topic: "last/words",
          will_qos: 3
        )
      end
    end

    test "outside 0..2 raises ArgumentError from MqttX.Client.connect/1 as well" do
      assert_raise ArgumentError, ~r/invalid :will_qos "1"/, fn ->
        MqttX.Client.connect(
          host: "localhost",
          port: 1,
          client_id: "will-qos-bad-connect",
          will_topic: "last/words",
          will_qos: "1"
        )
      end
    end

    test "a valid Will QoS is accepted and sent in CONNECT" do
      broker = FakeBroker.start()

      {:ok, client} =
        Connection.start_link(
          host: "localhost",
          port: broker.port,
          client_id: "will-qos-ok",
          will_topic: "last/words",
          will_qos: 2
        )

      on_exit(fn -> stop(client) end)

      assert_receive {:broker, :connect, %{will: %{qos: 2, topic: "last/words"}}}, 2_000
    end
  end
end
