defmodule MqttX.Client.PendingSeqRestoreTest do
  @moduledoc """
  `pending_seq` orders the resend of in-flight QoS 1/2 messages on session
  resumption (§4.4, §4.6). When a persisted session is loaded — a new VM
  incarnation taking over the same client id — the counter must continue
  above the restored entries, or everything published by the new incarnation
  would sort ahead of the older in-flight messages on the next resumption.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.Connection
  alias MqttX.Session.ETSStore
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  defp stop(client) do
    GenServer.stop(client, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  test "pending_seq continues above the in-flight entries loaded from the store" do
    table = :"pending_seq_#{System.unique_integer([:positive])}"
    client_id = "pending-seq-#{System.unique_integer([:positive])}"

    # Answers the CONNECT but never acknowledges a PUBLISH
    broker = FakeBroker.start()

    opts = [
      host: "localhost",
      port: broker.port,
      client_id: client_id,
      protocol_version: 5,
      clean_session: false,
      # Otherwise the v5 default (0) marks the record expired at disconnect
      connect_properties: %{session_expiry_interval: 3_600},
      session_store: {ETSStore, table: table},
      handler: ForwardingHandler,
      handler_state: %{pid: self()}
    ]

    {:ok, first} = Connection.start_link(opts)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    for i <- 1..3, do: assert(:ok = Connection.publish(first, "seq/#{i}", "p", qos: 1))
    for _ <- 1..3, do: assert_receive({:broker, :packet, %{type: :publish, qos: 1}}, 2_000)

    assert :sys.get_state(first).pending_seq == 3

    # terminate/2 persists the session
    stop(first)
    assert_receive {:broker, :closed}, 2_000
    assert {:ok, %{pending_acks: saved}} = ETSStore.load(client_id, %{table: table})
    assert map_size(saved) == 3

    # A new incarnation with the same id and store. `connack: :none` holds the
    # handshake open so the loaded state can be inspected before any CONNACK
    # touches it.
    quiet = FakeBroker.start(connack: :none)
    {:ok, second} = Connection.start_link(Keyword.put(opts, :port, quiet.port))
    on_exit(fn -> stop(second) end)

    state = :sys.get_state(second)

    restored = for {{:tx, _id}, %{seq: seq}} <- state.pending_acks, do: seq
    assert Enum.sort(restored) == [0, 1, 2]
    assert state.pending_seq == 3
  end

  test "pending_seq starts at 0 when the loaded session has nothing in flight" do
    table = :"pending_seq_#{System.unique_integer([:positive])}"
    client_id = "pending-seq-empty-#{System.unique_integer([:positive])}"
    {:ok, store} = ETSStore.init(table: table)

    :ok =
      ETSStore.save(
        client_id,
        %{
          packet_id: 9,
          pending_acks: %{},
          subscriptions: %{},
          expires_at: System.system_time(:second) + 3_600
        },
        store
      )

    quiet = FakeBroker.start(connack: :none)

    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: quiet.port,
        client_id: client_id,
        protocol_version: 5,
        clean_session: false,
        session_store: {ETSStore, table: table}
      )

    on_exit(fn -> stop(client) end)

    state = :sys.get_state(client)
    assert state.packet_id == 9
    assert state.pending_seq == 0
  end
end
