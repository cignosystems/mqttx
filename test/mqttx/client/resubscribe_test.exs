defmodule MqttX.Client.ResubscribeTest do
  # Regression test: subscriptions used to be untracked, so after any
  # reconnect the client stayed "connected" but received nothing.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  test "subscriptions are replayed after a reconnect without session resumption" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    # Close on failure too, not just on the happy path at the end of the test
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)
    parent = self()

    broker =
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

        {%{type: :subscribe} = sub, _buf} = recv_packet(sock, buf)
        send(parent, {:broker, :subscribe, sub})
        send_packet(sock, %{type: :suback, packet_id: sub.packet_id, acks: [{:ok, 1}]})

        # drop the connection to force a client reconnect
        receive do
          :kill_connection -> :gen_tcp.close(sock)
        end

        # --- second connection (reconnect) ---
        {:ok, sock2} = :gen_tcp.accept(listen, 10_000)
        {%{type: :connect}, buf2} = recv_packet(sock2, <<>>)

        send_packet(sock2, %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: %{}
        })

        {%{type: :subscribe} = resub, _} = recv_packet(sock2, buf2)
        send(parent, {:broker, :resubscribe, resub})
        send_packet(sock2, %{type: :suback, packet_id: resub.packet_id, acks: [{:ok, 1}]})

        receive do
          :done -> :gen_tcp.close(sock2)
        end
      end)

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: "resub-test",
        protocol_version: 5,
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    assert_receive {:mqtt_event, :connected, _}, 5_000

    assert {:ok, [1]} =
             MqttX.Client.Connection.subscribe(client, "sensors/#", qos: 1)

    assert_receive {:broker, :subscribe, first_sub}, 2_000
    assert [%{topic: ["sensors", :multi_level], qos: 1}] = first_sub.topics

    send(broker, :kill_connection)
    assert_receive {:mqtt_event, :disconnected, _}, 5_000

    # client reconnects (backoff ~1s) and must replay the subscription
    assert_receive {:mqtt_event, :connected, _}, 10_000
    assert_receive {:broker, :resubscribe, replayed}, 5_000
    assert [%{topic: ["sensors", :multi_level], qos: 1}] = replayed.topics

    send(broker, :done)
    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  defp recv_packet(sock, buffer) do
    case Codec.decode(5, buffer) do
      {:ok, {packet, rest}} ->
        {packet, rest}

      {:error, :incomplete} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_packet(sock, buffer <> data)
    end
  end

  defp send_packet(sock, packet_map) do
    {:ok, data} = Codec.encode(5, packet_map)
    :ok = :gen_tcp.send(sock, data)
  end
end
