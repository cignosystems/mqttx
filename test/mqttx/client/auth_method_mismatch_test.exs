defmodule MqttX.Client.AuthMethodMismatchTest do
  @moduledoc """
  §3.15.2.2.2 / MQTT-4.12.0-5: every AUTH, and a successful CONNACK, names
  the Authentication Method the CONNECT asked for. The client treats another
  method as a Protocol Error instead of handing it to `handle_auth/3`.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker

  defmodule AuthHandler do
    @moduledoc false
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end

    def handle_auth(reason_code, props, %{pid: pid} = state) do
      send(pid, {:handle_auth, reason_code, props})
      {:continue, "proof", state}
    end
  end

  @method "SCRAM-SHA-256"

  defp start_client(broker, client_id) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: client_id,
        protocol_version: 5,
        connect_properties: %{authentication_method: @method},
        handler: AuthHandler,
        handler_state: %{pid: self()}
      )

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  defp auth(reason_code, properties),
    do: %{type: :auth, reason_code: reason_code, properties: properties}

  defp connack(properties),
    do: %{type: :connack, session_present: false, reason_code: 0, properties: properties}

  test "an AUTH naming another method during the handshake fails the connect" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "auth-wrong-method")
    waiter = Task.async(fn -> Connection.await_connect(client, 5_000) end)
    assert_receive {:broker, :connect, _}, 2_000

    FakeBroker.send(
      broker,
      auth(0x18, %{authentication_method: "OTHER", authentication_data: "x"})
    )

    assert Task.await(waiter) == {:error, {:protocol_error, :authentication_method_mismatch}}
    assert_receive {:broker, :closed}, 2_000
    refute_received {:handle_auth, _, _}
    refute Connection.connected?(client)
  end

  test "an AUTH without any method during the handshake fails the connect too" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "auth-no-method")
    waiter = Task.async(fn -> Connection.await_connect(client, 5_000) end)
    assert_receive {:broker, :connect, _}, 2_000

    FakeBroker.send(broker, auth(0x18, %{authentication_data: "x"}))

    assert Task.await(waiter) == {:error, {:protocol_error, :authentication_method_mismatch}}
    refute_received {:handle_auth, _, _}
  end

  test "a successful CONNACK naming another method is refused; one omitting it is accepted" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "connack-wrong-method")
    waiter = Task.async(fn -> Connection.await_connect(client, 5_000) end)
    assert_receive {:broker, :connect, _}, 2_000

    FakeBroker.send(broker, connack(%{authentication_method: "OTHER"}))
    assert Task.await(waiter) == {:error, {:protocol_error, :authentication_method_mismatch}}
    refute Connection.connected?(client)

    lax = FakeBroker.start(connack: :none)
    client = start_client(lax, "connack-no-method")
    assert_receive {:broker, :connect, _}, 2_000
    FakeBroker.send(lax, connack(%{}))
    assert_receive {:mqtt_event, :connected, _}, 2_000
    assert Connection.connected?(client)
  end

  test "an AUTH naming another method on a live connection gets DISCONNECT 0x82" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "live-wrong-method")
    assert_receive {:broker, :connect, _}, 2_000
    FakeBroker.send(broker, connack(%{authentication_method: @method}))
    assert_receive {:mqtt_event, :connected, _}, 2_000

    FakeBroker.send(
      broker,
      auth(0x18, %{authentication_method: "OTHER", authentication_data: "x"})
    )

    assert_receive {:broker, :packet, %{type: :disconnect, reason_code: 0x82}}, 2_000

    assert_receive {:mqtt_event, :disconnected,
                    {:protocol_error, :authentication_method_mismatch}},
                   2_000

    refute_received {:handle_auth, _, _}
    refute Connection.connected?(client)
  end

  test "an AUTH naming the CONNECT's method still reaches the handler" do
    broker = FakeBroker.start(connack: :none)
    _client = start_client(broker, "auth-right-method")
    assert_receive {:broker, :connect, _}, 2_000

    FakeBroker.send(
      broker,
      auth(0x18, %{authentication_method: @method, authentication_data: "n"})
    )

    assert_receive {:handle_auth, 0x18, %{authentication_data: "n"}}, 2_000

    assert_receive {:broker, :packet,
                    %{type: :auth, properties: %{authentication_data: "proof"}}},
                   2_000
  end
end
