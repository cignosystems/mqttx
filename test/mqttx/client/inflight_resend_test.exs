defmodule MqttX.Client.InflightResendTest do
  # Regression tests for §4.4/§4.6: unacknowledged QoS 1/2 messages must be
  # resent promptly (dup=1) when a reconnect resumes the session, and
  # discarded when the broker starts a fresh session (MQTT-3.2.2-4).
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  defp start_broker(listen, parent, second_session_present) do
    spawn_link(fn ->
      # --- first connection ---
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {%{type: :connect}, buf} = recv_packet(sock, <<>>)

      send_packet(sock, %{
        type: :connack,
        session_present: false,
        reason_code: 0,
        properties: %{}
      })

      # receive the QoS 1 PUBLISH but never acknowledge it
      {%{type: :publish} = pub, _buf} = recv_packet(sock, buf)
      send(parent, {:broker, :got_publish, pub})

      receive do
        :kill_connection -> :gen_tcp.close(sock)
      end

      # --- second connection (reconnect) ---
      {:ok, sock2} = :gen_tcp.accept(listen, 10_000)
      {%{type: :connect}, buf2} = recv_packet(sock2, <<>>)

      send_packet(sock2, %{
        type: :connack,
        session_present: second_session_present,
        reason_code: 0,
        properties: %{}
      })

      # forward whatever the client sends next (resent PUBLISH — or, when the
      # session was not resumed, nothing)
      relay_loop(sock2, parent)
    end)
  end

  defp relay_loop(sock, parent, buf \\ <<>>) do
    case recv_packet(sock, buf, 3_000) do
      {packet, rest} ->
        send(parent, {:broker, :packet, packet})
        relay_loop(sock, parent, rest)

      :timeout ->
        relay_loop(sock, parent, buf)
    end
  end

  defp connect_client(port) do
    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: "inflight-test",
        protocol_version: 5,
        clean_session: false,
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    assert_receive {:mqtt_event, :connected, _}, 5_000
    client
  end

  test "unacked QoS 1 PUBLISH is resent with dup=1 immediately after session resumption" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    broker = start_broker(listen, self(), true)

    client = connect_client(port)

    assert :ok = MqttX.Client.Connection.publish(client, "jobs/1", "payload", qos: 1)
    assert_receive {:broker, :got_publish, original}, 2_000
    assert original.dup == false

    send(broker, :kill_connection)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 10_000

    # Prompt resend: well before the 5s retry_interval, with dup=1 and the
    # same packet id
    assert_receive {:broker, :packet, %{type: :publish} = resent}, 3_000
    assert resent.dup == true
    assert resent.packet_id == original.packet_id
    assert resent.payload == "payload"

    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  test "in-flight state is discarded when the broker starts a fresh session" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    broker = start_broker(listen, self(), false)

    client = connect_client(port)

    assert :ok = MqttX.Client.Connection.publish(client, "jobs/1", "payload", qos: 1)
    assert_receive {:broker, :got_publish, _original}, 2_000

    send(broker, :kill_connection)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000
    assert_receive {:mqtt_event, :connected, %{session_present: false}}, 10_000

    # MQTT-3.2.2-4: no replay into the fresh session — wait past the retry
    # interval trigger point to be sure the periodic retry doesn't fire either
    refute_receive {:broker, :packet, %{type: :publish}}, 1_500

    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  defp recv_packet(sock, buffer, timeout \\ 5_000) do
    case Codec.decode(5, buffer) do
      {:ok, {packet, rest}} ->
        {packet, rest}

      {:error, :incomplete} ->
        case :gen_tcp.recv(sock, 0, timeout) do
          {:ok, data} -> recv_packet(sock, buffer <> data, timeout)
          {:error, :timeout} -> :timeout
          {:error, :closed} -> exit(:normal)
        end
    end
  end

  defp send_packet(sock, packet_map) do
    {:ok, data} = Codec.encode(5, packet_map)
    :ok = :gen_tcp.send(sock, data)
  end
end
