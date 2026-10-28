defmodule MqttX.Client.ConnectionGuardrailsTest do
  @moduledoc """
  The connection process stays answerable and alive in the corners the last
  review found: while a socket is being opened, when a handler throws, when a
  payload is not bytes, when a WebSocket closes mid-handshake, when an
  UNSUBACK refuses a filter, and when a resumed session has more in flight
  than the broker's Receive Maximum allows at once.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection
  alias MqttX.Client.WebSocket
  alias MqttX.Test.FakeBroker
  alias MqttX.Test.ForwardingHandler

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defmodule ThrowingHandler do
    def handle_mqtt_event(:connected, _info, state) do
      send(state.pid, :about_to_throw)
      throw(:not_an_exception)
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  defp start_client(broker, opts \\ []) do
    {:ok, client} =
      Connection.start_link(
        [
          host: "localhost",
          port: broker.port,
          client_id: "guardrails-#{System.unique_integer([:positive])}",
          protocol_version: 5,
          handler: ForwardingHandler,
          handler_state: %{pid: self()}
        ] ++ opts
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

  # Accepts, then drips one byte every 200 ms: an upgrade that never completes
  defp drip_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      drip(socket)
    end)

    port
  end

  defp drip(socket) do
    case :gen_tcp.send(socket, "H") do
      :ok ->
        Process.sleep(200)
        drip(socket)

      _ ->
        :ok
    end
  end

  test "calls are answered while the socket is still being opened" do
    port = drip_server()

    capture_log(fn ->
      {:ok, pid} =
        MqttX.Client.connect(host: "127.0.0.1", port: port, transport: :ws, client_id: "busy")

      started = System.monotonic_time(:millisecond)
      assert {:error, :not_connected} = MqttX.Client.publish(pid, "t", "x")
      assert {:error, :not_connected} = MqttX.Client.subscribe(pid, "t")
      # Well within the upgrade's own deadline: the process was never held
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert :sys.get_state(pid).connecting
      GenServer.stop(pid)
    end)
  end

  test "a handler that throws is logged and the connection lives on" do
    broker = FakeBroker.start()

    log =
      capture_log(fn ->
        {:ok, client} =
          Connection.start_link(
            host: "localhost",
            port: broker.port,
            client_id: "thrower",
            protocol_version: 5,
            handler: ThrowingHandler,
            handler_state: %{pid: self()}
          )

        assert_receive :about_to_throw, 5_000
        # Still here, still connected, and the handler's error is on record
        assert :sys.get_state(client).connected
        assert :ok = Connection.publish(client, "t", "x")
        assert_receive {:broker, :packet, %{type: :publish}}, 2_000
        GenServer.stop(client)
      end)

    assert log =~ "threw on :connected"
    assert log =~ ":not_an_exception"
  end

  test "a payload that is not bytes is refused; iodata is sent as bytes" do
    broker = FakeBroker.start()
    client = start_client(broker)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    assert {:error, :invalid_payload} = Connection.publish(client, "t", %{not: :bytes})
    assert {:error, :invalid_payload} = Connection.publish(client, "t", 42)
    assert {:error, :invalid_payload} = Connection.publish(client, "t", [:atom])

    assert :ok = Connection.publish(client, "t", ["ab", ?c, [<<"d">>]])
    assert_receive {:broker, :packet, %{type: :publish, payload: "abcd"}}, 2_000
    assert :sys.get_state(client).connected
  end

  test "an UNSUBACK refusing a filter is an error to the caller" do
    broker = FakeBroker.start()
    client = start_client(broker)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    task = Task.async(fn -> Connection.unsubscribe(client, ["a/b", "c/d"]) end)
    assert_receive {:broker, :packet, %{type: :unsubscribe, packet_id: id}}, 2_000

    FakeBroker.send(broker, %{
      type: :unsuback,
      packet_id: id,
      acks: [{:ok, :found}, {:error, 0x87}],
      properties: %{}
    })

    assert {:error, {:unsubscribe_failed, [0x87]}} = Task.await(task, 2_000)

    # One that worked throughout still answers :ok
    task = Task.async(fn -> Connection.unsubscribe(client, ["e/f"]) end)
    assert_receive {:broker, :packet, %{type: :unsubscribe, packet_id: id}}, 2_000

    FakeBroker.send(broker, %{
      type: :unsuback,
      packet_id: id,
      acks: [{:ok, :found}],
      properties: %{}
    })

    assert :ok = Task.await(task, 2_000)
  end

  test "a WebSocket closed during the handshake ends the attempt at once" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    # Upgrades, reads the CONNECT, and hangs up instead of answering it
    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      request = recv_until(sock, <<>>, "\r\n\r\n")
      [_, key] = Regex.run(~r/Sec-WebSocket-Key:\s*([^\r\n]+)/i, request)
      accept = Base.encode64(:crypto.hash(:sha, String.trim(key) <> @ws_guid))

      :ok =
        :gen_tcp.send(
          sock,
          "HTTP/1.1 101 Switching Protocols\r\n" <>
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" <>
            "Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n"
        )

      [_connect] = recv_payloads(sock, <<>>)
      :gen_tcp.close(sock)
    end)

    capture_log(fn ->
      started = System.monotonic_time(:millisecond)

      result =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          transport: :ws,
          client_id: "ws-hangup",
          await_connect: true
        )

      assert {:error, :closed} = result
      # Not the 5 s CONNACK deadline: the close itself ended the attempt
      assert System.monotonic_time(:millisecond) - started < 3_000
    end)
  end

  test "a resumed session re-sends no more at once than the broker's Receive Maximum" do
    broker = FakeBroker.start(connack: :none)

    client =
      start_client(broker,
        clean_session: false,
        connect_properties: %{session_expiry_interval: 3600}
      )

    assert_receive {:broker, :connect, _}, 5_000

    FakeBroker.send(broker, %{
      type: :connack,
      session_present: false,
      reason_code: 0,
      properties: %{receive_maximum: 10}
    })

    assert_receive {:mqtt_event, :connected, _}, 5_000

    # Three in flight, none acknowledged
    for n <- 1..3, do: assert(:ok = Connection.publish(client, "jobs/#{n}", "p#{n}", qos: 1))
    for _ <- 1..3, do: assert_receive({:broker, :packet, %{type: :publish}}, 2_000)

    FakeBroker.close(broker)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    assert_receive {:broker, :connect, _}, 10_000

    # The session is back, but this time only one message may be in flight
    FakeBroker.send(broker, %{
      type: :connack,
      session_present: true,
      reason_code: 0,
      properties: %{receive_maximum: 1}
    })

    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 5_000

    assert_receive {:broker, :packet, %{type: :publish, dup: true, topic: ["jobs", "1"]} = first},
                   2_000

    refute_receive {:broker, :packet, %{type: :publish}}, 300

    # Each acknowledgement lets the next one out, in order
    FakeBroker.send(broker, %{
      type: :puback,
      packet_id: first.packet_id,
      reason_code: 0,
      properties: %{}
    })

    assert_receive {:broker, :packet,
                    %{type: :publish, dup: true, topic: ["jobs", "2"]} = second},
                   2_000

    refute_receive {:broker, :packet, %{type: :publish}}, 300

    # A new publish waits its turn behind the backlog
    assert {:error, :flow_control} = Connection.publish(client, "jobs/new", "n", qos: 1)

    FakeBroker.send(broker, %{
      type: :puback,
      packet_id: second.packet_id,
      reason_code: 0,
      properties: %{}
    })

    assert_receive {:broker, :packet, %{type: :publish, dup: true, topic: ["jobs", "3"]} = third},
                   2_000

    FakeBroker.send(broker, %{
      type: :puback,
      packet_id: third.packet_id,
      reason_code: 0,
      properties: %{}
    })

    Process.sleep(50)

    assert :ok = Connection.publish(client, "jobs/new", "n", qos: 1)
    assert_receive {:broker, :packet, %{type: :publish, topic: ["jobs", "new"]}}, 2_000
  end

  defp publish_bytes(id, qos, payload \\ "p") do
    {:ok, bytes} =
      MqttX.Packet.Codec.encode(5, %{
        type: :publish,
        topic: "in/#{id}",
        payload: payload,
        qos: qos,
        retain: false,
        dup: false,
        packet_id: if(qos > 0, do: id),
        properties: %{}
      })

    bytes
  end

  defp acks(type, n) do
    for _ <- 1..n do
      assert_receive {:broker, :packet, %{type: ^type, packet_id: id}}, 2_000
      id
    end
  end

  test "the acknowledgements of a read's packets go out together, in order" do
    broker = FakeBroker.start()
    client = start_client(broker)
    assert_receive {:mqtt_event, :connected, _}, 5_000

    # Four messages in one read: their PUBACKs and the PUBREC leave in one
    # write, in order, after every message reached the handler
    read =
      publish_bytes(1, 1) <> publish_bytes(2, 1) <> publish_bytes(3, 2) <> publish_bytes(4, 1)

    FakeBroker.send_raw(broker, read)

    for id <- ["1", "2", "4"],
        do: assert_receive({:mqtt_event, :message, {["in", ^id], _, _}}, 2_000)

    assert acks(:puback, 3) == [1, 2, 4]
    assert [3] = acks(:pubrec, 1)
    assert :sys.get_state(client).inflight_rx_count == 1

    FakeBroker.send(broker, %{type: :pubrel, packet_id: 3, reason_code: 0, properties: %{}})
    assert_receive {:mqtt_event, :message, {["in", "3"], _, _}}, 2_000
    assert [3] = acks(:pubcomp, 1)
    assert :sys.get_state(client).inflight_rx_count == 0
    assert :sys.get_state(client).ack_out == []
  end

  test "QoS 2 messages in flight are counted against the Receive Maximum advertised" do
    broker = FakeBroker.start()
    client = start_client(broker, connect_properties: %{receive_maximum: 2})
    assert_receive {:mqtt_event, :connected, _}, 5_000

    FakeBroker.send_raw(broker, publish_bytes(1, 2) <> publish_bytes(2, 2))
    assert acks(:pubrec, 2) == [1, 2]
    assert :sys.get_state(client).inflight_rx_count == 2

    # The same one again (a re-send) is within the window; a third is not
    FakeBroker.send_raw(broker, publish_bytes(2, 2))
    assert [2] = acks(:pubrec, 1)
    assert :sys.get_state(client).inflight_rx_count == 2

    FakeBroker.send_raw(broker, publish_bytes(3, 2))
    assert_receive {:broker, :packet, %{type: :disconnect, reason_code: 0x93}}, 2_000

    assert_receive {:mqtt_event, :disconnected, {:protocol_error, :receive_maximum_exceeded}},
                   2_000
  end

  defp recv_until(sock, buffer, marker) do
    if String.contains?(buffer, marker) do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      recv_until(sock, buffer <> data, marker)
    end
  end

  defp recv_payloads(sock, buffer) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)

    case WebSocket.decode_frames(buffer <> data) do
      {:ok, [], [], rest, _frag} -> recv_payloads(sock, rest)
      {:ok, payloads, _pings, _rest, _frag} -> payloads
    end
  end
end
