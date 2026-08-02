defmodule MqttX.Client.SessionKeyTest do
  @moduledoc """
  The session store must be keyed by the client id we configured, never by the
  Assigned Client Identifier a broker returns in CONNACK (§3.2.2.3.7).

  `apply_connack_settings/2` used to adopt that property unconditionally and
  `save_session/1` used the same field as the store key, so a hostile broker
  could rename this connection to another client's id and overwrite that
  client's persisted session in the shared `:mqttx_sessions` table — the victim
  would then replay the attacker-influenced subscriptions and in-flight
  publishes against its own broker.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  # A broker that answers CONNACK with an Assigned Client Identifier of its
  # choosing — the hostile behaviour under test.
  defp start_broker(listen, assigned_id) do
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)

      props = if assigned_id, do: %{assigned_client_identifier: assigned_id}, else: %{}

      {:ok, connack} =
        Codec.encode(5, %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: props
        })

      :ok = :gen_tcp.send(sock, connack)
      send(parent, :broker_ready)

      receive do
        :done -> :gen_tcp.close(sock)
      after
        15_000 -> :ok
      end
    end)
  end

  setup do
    table = :"session_key_test_#{System.unique_integer([:positive])}"
    MqttX.Session.ETSOwner.ensure_table(table)
    on_exit(fn -> :ets.delete_all_objects(table) end)
    {:ok, table: table}
  end

  defp connect(port, client_id, table) do
    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: client_id,
        protocol_version: 5,
        clean_session: false,
        session_store: {MqttX.Session.ETSStore, table: table},
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    client
  end

  test "a broker's Assigned Client Identifier does not become the session key", %{table: table} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)

    # The victim already has a persisted session under its own id
    :ets.insert(table, {"victim-client", %{subscriptions: %{"victim/topic" => 1}, packet_id: 7}})

    broker = start_broker(listen, "victim-client")
    client = connect(port, "attacker-client", table)

    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    # Force a session save
    send(broker, :done)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    Process.sleep(200)

    assert [{"victim-client", victim_session}] = :ets.lookup(table, "victim-client"),
           "the victim's session record was destroyed"

    assert victim_session.subscriptions == %{"victim/topic" => 1},
           "the victim's session was overwritten by another connection"

    # The attacker's own session is stored under the id it actually configured
    assert [{"attacker-client", _}] = :ets.lookup(table, "attacker-client")

    try do
      GenServer.stop(client, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end

  test "the Assigned Client Identifier is ignored when we supplied a client id", %{table: table} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)

    broker = start_broker(listen, "server-chosen-id")
    client = connect(port, "my-configured-id", table)

    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    # §3.2.2.3.7: we sent a non-empty id, so the server had no business
    # assigning one — the connection keeps the id we configured.
    assert :sys.get_state(client).client_id == "my-configured-id"

    send(broker, :done)

    try do
      GenServer.stop(client, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
end
