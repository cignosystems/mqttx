defmodule MqttX.SimpleClientTest do
  # Tests for `use MqttX` (GitHub issue #1): module-based client with
  # callbacks running in their own process.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule EchoClient do
    use MqttX

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def handle_connected(info, state) do
      send(state.test_pid, {:client_connected, info})
      {:ok, state}
    end

    @impl true
    def handle_disconnected(reason, state) do
      send(state.test_pid, {:client_disconnected, reason})
      {:ok, state}
    end

    @impl true
    def handle_message(topic, payload, _packet, state) do
      send(state.test_pid, {:client_message, topic, payload})
      # The core ask from the issue: publish in reaction to a message.
      # This must not deadlock even though we're inside a callback.
      :ok = publish("echo/" <> Enum.join(topic, "/"), "echo:" <> payload, qos: 0)
      {:ok, state}
    end
  end

  test "module client connects, receives, and can publish from inside a callback" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    broker =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {%{type: :connect}, buf} = recv_packet(sock, <<>>)

        send_packet(sock, %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: %{}
        })

        # Deliver a PUBLISH to the client...
        send_packet(sock, %{
          type: :publish,
          topic: "cmd/reboot",
          payload: "now",
          qos: 0,
          retain: false,
          dup: false,
          properties: %{}
        })

        # ...and expect the client's echo publish back (sent from within
        # handle_message)
        {%{type: :publish} = echoed, _} = recv_packet(sock, buf)
        send(parent, {:broker_got_echo, echoed})

        receive do
          :stop -> :gen_tcp.close(sock)
        after
          10_000 -> :gen_tcp.close(sock)
        end
      end)

    {:ok, pid} =
      EchoClient.start_link(
        host: "localhost",
        port: port,
        client_id: "simple-test",
        protocol_version: 5,
        test_pid: self()
      )

    assert_receive {:client_connected, %{session_present: false}}, 5_000
    assert_receive {:client_message, ["cmd", "reboot"], "now"}, 5_000

    # The echo publish made it to the broker — no deadlock
    assert_receive {:broker_got_echo, echoed}, 5_000
    assert echoed.topic == ["echo", "cmd", "reboot"]
    assert echoed.payload == "echo:now"

    # Injected helpers work from outside the client process too
    assert EchoClient.connected?()
    assert :ok = EchoClient.publish("outside/topic", "external", qos: 0)

    send(broker, :stop)
    assert_receive {:client_disconnected, _}, 5_000

    EchoClient.disconnect()
    :gen_tcp.close(listen)
  end

  test "default callbacks make a bare module valid" do
    defmodule BareClient do
      use MqttX
    end

    assert {:ok, %{}} = BareClient.init([])
    assert {:ok, :s} = BareClient.handle_message(["t"], "p", %{}, :s)
    assert {:ok, :s} = BareClient.handle_connected(%{}, :s)
    assert {:ok, :s} = BareClient.handle_disconnected(:closed, :s)
    assert {:ok, :s} = BareClient.handle_info(:anything, :s)

    assert %{restart: :transient, start: {BareClient, :start_link, _}} =
             BareClient.child_spec([])
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
