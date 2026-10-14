defmodule MqttX.Client.SessionExpiryTest do
  @moduledoc """
  The persisted session record carries `expires_at`, derived from the
  negotiated Session Expiry Interval (§3.1.2.11.2): the CONNECT property,
  overridden by CONNACK (§3.2.2.3.2), revisable on DISCONNECT (§3.14.2.2.2).
  An expired record is discarded on load, and a clean start deletes any
  stored record (§3.1.2.4).
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec
  alias MqttX.Session.ETSStore

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  # A minimal broker: accept one connection, answer CONNACK with the given
  # properties, then close when told to.
  defp start_broker(listen, version, connack_props) do
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)

      {:ok, connack} =
        Codec.encode(version, %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: connack_props
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
    table = :"session_expiry_test_#{System.unique_integer([:positive])}"
    {:ok, store_state} = ETSStore.init(table: table)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)
    {:ok, table: table, store: store_state, listen: listen, port: port}
  end

  defp connect(ctx, client_id, opts) do
    {:ok, client} =
      MqttX.Client.Connection.start_link(
        Keyword.merge(
          [
            host: "localhost",
            port: ctx.port,
            client_id: client_id,
            protocol_version: 5,
            clean_session: false,
            session_store: {ETSStore, table: ctx.table},
            handler: Forwarder,
            handler_state: %{pid: self()}
          ],
          opts
        )
      )

    client
  end

  defp stop(client) do
    GenServer.stop(client, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  # Drive a full connect → broker close → save cycle and return the record
  defp saved_record(ctx, client_id, version, connect_opts, connack_props) do
    broker = start_broker(ctx.listen, version, connack_props)
    client = connect(ctx, client_id, Keyword.put(connect_opts, :protocol_version, version))

    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    send(broker, :done)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    Process.sleep(100)

    {:ok, record} = ETSStore.load(client_id, ctx.store)
    stop(client)
    record
  end

  test "expires_at follows the CONNECT Session Expiry Interval", ctx do
    record =
      saved_record(
        ctx,
        "sei-connect",
        5,
        [connect_properties: %{session_expiry_interval: 3_600}],
        %{}
      )

    assert record.expires_at == record.saved_at + 3_600
    assert_in_delta record.saved_at, System.system_time(:second), 5
  end

  test "a CONNACK Session Expiry Interval overrides the CONNECT value (§3.2.2.3.2)", ctx do
    record =
      saved_record(
        ctx,
        "sei-connack",
        5,
        [connect_properties: %{session_expiry_interval: 3_600}],
        %{session_expiry_interval: 30}
      )

    assert record.expires_at == record.saved_at + 30
  end

  test "a v5 connection without the property expires at disconnect (interval 0)", ctx do
    record = saved_record(ctx, "sei-default", 5, [], %{})
    assert record.expires_at == record.saved_at
  end

  test "0xFFFFFFFF never expires", ctx do
    record =
      saved_record(
        ctx,
        "sei-forever",
        5,
        [connect_properties: %{session_expiry_interval: 0xFFFFFFFF}],
        %{}
      )

    assert record.expires_at == nil
  end

  test "a v3.1.1 session has no expiry", ctx do
    record = saved_record(ctx, "sei-v4", 4, [], %{})
    assert record.expires_at == nil
    assert is_integer(record.saved_at)
  end

  test "a client DISCONNECT can revise the interval (§3.14.2.2.2)", ctx do
    _broker = start_broker(ctx.listen, 5, %{})

    client =
      connect(ctx, "sei-revise", connect_properties: %{session_expiry_interval: 3_600})

    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    MqttX.Client.Connection.disconnect(client, properties: %{session_expiry_interval: 0})
    Process.sleep(200)

    {:ok, record} = ETSStore.load("sei-revise", ctx.store)
    assert record.expires_at == record.saved_at
  end

  test "an expired record is discarded and deleted on load", ctx do
    past = System.system_time(:second) - 10

    :ok =
      ETSStore.save(
        "sei-expired",
        %{packet_id: 77, pending_acks: %{{:tx, 5} => %{}}, subscriptions: %{}, expires_at: past},
        ctx.store
      )

    _broker = start_broker(ctx.listen, 5, %{})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        client = connect(ctx, "sei-expired", [])
        assert_receive :broker_ready, 5_000
        assert_receive {:mqtt_event, :connected, _}, 5_000

        state = :sys.get_state(client)
        assert state.packet_id == 1
        assert state.pending_acks == %{}
        stop(client)
      end)

    assert log =~ "expired — starting fresh"
  end

  test "a live record is still loaded", ctx do
    future = System.system_time(:second) + 3_600

    :ok =
      ETSStore.save(
        "sei-live",
        %{packet_id: 77, pending_acks: %{}, subscriptions: %{}, expires_at: future},
        ctx.store
      )

    _broker = start_broker(ctx.listen, 5, %{})
    client = connect(ctx, "sei-live", [])
    assert_receive :broker_ready, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000

    assert :sys.get_state(client).packet_id == 77
    stop(client)
  end

  test "a clean start deletes the stored record (§3.1.2.4)", ctx do
    :ok = ETSStore.save("sei-clean", %{packet_id: 77}, ctx.store)

    _broker = start_broker(ctx.listen, 5, %{})
    client = connect(ctx, "sei-clean", clean_session: true)

    # init/1 runs synchronously inside start_link, so the delete is done
    assert :not_found = ETSStore.load("sei-clean", ctx.store)

    assert_receive :broker_ready, 5_000
    stop(client)
  end
end
