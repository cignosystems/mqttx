defmodule MqttX.Client.EnhancedAuthTest do
  @moduledoc """
  MQTT 5.0 enhanced authentication on the client (§4.12). An AUTH 0x18 from
  the broker is handed to the handler's `handle_auth/3`; `{:continue, data,
  state}` goes back as AUTH 0x18 carrying `data`, `{:ok, state}` just waits.
  During the handshake the exchange ends with the broker's CONNACK; on a live
  connection it is a re-authentication and ends with AUTH 0x00.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defmodule AuthHandler do
    @moduledoc false
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end

    # Answer the first challenge with the configured proof, accept what follows
    def handle_auth(reason_code, props, %{pid: pid} = state) do
      send(pid, {:handle_auth, reason_code, props})

      case Map.pop(state, :proof) do
        {nil, state} -> {:ok, state}
        {proof, state} -> {:continue, proof, state}
      end
    end
  end

  @method "SCRAM-SHA-256"

  defp start_client(broker, client_id, handler, handler_state) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: broker.port,
        client_id: client_id,
        protocol_version: 5,
        connect_properties: %{authentication_method: @method},
        handler: handler,
        handler_state: handler_state
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

  defp auth(reason_code, nil) do
    %{type: :auth, reason_code: reason_code, properties: %{authentication_method: @method}}
  end

  defp auth(reason_code, data) do
    %{
      type: :auth,
      reason_code: reason_code,
      properties: %{authentication_method: @method, authentication_data: data}
    }
  end

  defp connack, do: %{type: :connack, session_present: false, reason_code: 0, properties: %{}}

  test "a challenge during the handshake is answered and the connect completes on CONNACK" do
    broker = FakeBroker.start(connack: :none)

    client =
      start_client(broker, "auth-handshake", AuthHandler, %{pid: self(), proof: "client-proof"})

    assert_receive {:broker, :connect, %{properties: %{authentication_method: @method}}}, 2_000

    FakeBroker.send(broker, auth(0x18, "server-nonce"))

    assert_receive {:handle_auth, 0x18, %{authentication_data: "server-nonce"}}, 2_000

    assert_receive {:broker, :packet,
                    %{
                      type: :auth,
                      reason_code: 0x18,
                      properties: %{
                        authentication_method: @method,
                        authentication_data: "client-proof"
                      }
                    }},
                   2_000

    # Still in the handshake until the broker says so
    refute Connection.connected?(client)

    FakeBroker.send(broker, connack())

    assert_receive {:mqtt_event, :connected, _}, 2_000
    assert Connection.connected?(client)
  end

  test "a handler without handle_auth/3 lets the handshake run on to CONNACK" do
    broker = FakeBroker.start(connack: :none)
    client = start_client(broker, "auth-no-callback", ForwardingHandler, %{pid: self()})

    assert_receive {:broker, :connect, _}, 2_000

    FakeBroker.send(broker, auth(0x18, "server-nonce"))
    refute_receive {:broker, :packet, _}, 200
    refute Connection.connected?(client)

    FakeBroker.send(broker, connack())
    assert_receive {:mqtt_event, :connected, _}, 2_000
  end

  describe "without an Authentication Method in CONNECT (MQTT-4.12.0-7)" do
    # Same handler, but the CONNECT does not opt into enhanced authentication
    defp start_plain_client(broker, client_id) do
      {:ok, client} =
        Connection.start_link(
          host: "localhost",
          port: broker.port,
          client_id: client_id,
          protocol_version: 5,
          handler: AuthHandler,
          handler_state: %{pid: self(), proof: "would-be-proof"}
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

    test "an AUTH during the handshake fails the connect as a protocol error" do
      broker = FakeBroker.start(connack: :none)
      client = start_plain_client(broker, "auth-unexpected-handshake")
      waiter = Task.async(fn -> Connection.await_connect(client, 5_000) end)

      assert_receive {:broker, :connect, connect}, 2_000
      refute Map.has_key?(connect.properties, :authentication_method)

      FakeBroker.send(broker, auth(0x18, "server-nonce"))

      assert Task.await(waiter) == {:error, {:protocol_error, :unexpected_auth}}
      assert_receive {:broker, :closed}, 2_000

      # Never handed to the handler, never answered
      refute_received {:handle_auth, _, _}
      refute_received {:broker, :packet, %{type: :auth}}
      refute Connection.connected?(client)
    end

    test "an AUTH on a live connection gets DISCONNECT 0x82 and tears the connection down" do
      broker = FakeBroker.start()
      client = start_plain_client(broker, "auth-unexpected-live")
      assert_receive {:mqtt_event, :connected, _}, 5_000

      FakeBroker.send(broker, auth(0x18, "new-nonce"))

      assert_receive {:broker, :packet, %{type: :disconnect, reason_code: 0x82}}, 2_000
      assert_receive {:mqtt_event, :disconnected, {:protocol_error, :unexpected_auth}}, 2_000
      assert_receive {:broker, :closed}, 2_000

      refute_received {:handle_auth, _, _}
      refute_received {:broker, :packet, %{type: :auth}}
      refute Connection.connected?(client)
    end
  end

  test "re-authentication on a live connection round-trips through the handler" do
    broker = FakeBroker.start()

    client =
      start_client(broker, "auth-reauth", AuthHandler, %{pid: self(), proof: "fresh-proof"})

    assert_receive {:mqtt_event, :connected, _}, 5_000

    # Broker-initiated re-authentication (§4.12.1)
    FakeBroker.send(broker, auth(0x18, "new-nonce"))

    assert_receive {:handle_auth, 0x18, %{authentication_data: "new-nonce"}}, 2_000

    assert_receive {:broker, :packet,
                    %{
                      type: :auth,
                      reason_code: 0x18,
                      properties: %{authentication_data: "fresh-proof"}
                    }},
                   2_000

    FakeBroker.send(broker, auth(0x00, nil))

    assert_receive {:handle_auth, 0x00, _}, 2_000
    refute_receive {:mqtt_event, :disconnected, _}, 200
    assert Connection.connected?(client)
  end
end
