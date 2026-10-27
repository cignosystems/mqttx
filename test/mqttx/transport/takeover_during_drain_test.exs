defmodule MqttX.Transport.TakeoverDuringDrainTest do
  @moduledoc """
  A client that reconnects while its previous connection is still being
  drained after a close the broker decided on (here a protocol error) is
  taken over at once and keeps its session: the connection being drained
  hands the session over instead of ending it — and starting its expiry —
  after the new connection has resumed it.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec
  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  defp start(MqttX.Transport.Ranch) do
    refs_before = MapSet.new(Map.keys(:ranch.info()))
    name = :"drain_takeover_ranch_#{System.unique_integer([:positive])}"

    {:ok, listener} =
      MqttX.Server.start_link(ClusterBroker, [],
        transport: MqttX.Transport.Ranch,
        port: 0,
        name: name
      )

    [ref] = Map.keys(:ranch.info()) |> Enum.reject(&MapSet.member?(refs_before, &1))
    on_exit(fn -> if Process.alive?(listener), do: Process.exit(listener, :shutdown) end)
    {name, :ranch.get_port(ref)}
  end

  defp start(MqttX.Transport.ThousandIsland) do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    name = :"drain_takeover_ti_#{port}"
    {:ok, server, owner} = ClusterBroker.start_listener(name, port)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {name, port}
  end

  defp recv_packet(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    {:ok, {packet, <<>>}} = Codec.decode(5, data)
    packet
  end

  for transport <- [MqttX.Transport.ThousandIsland, MqttX.Transport.Ranch] do
    test "#{inspect(transport)}: a reconnect during the drain is taken over at once and keeps the session" do
      {name, port} = start(unquote(transport))
      client_id = "drain-takeover"

      # A persistent session (expiry 1 s) over a raw socket, subscribed
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

      {:ok, connect} =
        Codec.encode(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: client_id,
          username: nil,
          password: nil,
          will: nil,
          clean_session: true,
          keep_alive: 60,
          properties: %{session_expiry_interval: 1}
        })

      :ok = :gen_tcp.send(socket, connect)
      assert %{type: :connack, reason_code: 0} = recv_packet(socket)

      {:ok, subscribe} =
        Codec.encode(5, %{
          type: :subscribe,
          packet_id: 1,
          topics: [%{topic: "d/#", qos: 1}],
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, subscribe)
      assert %{type: :suback} = recv_packet(socket)

      # A second CONNECT is a protocol error (§3.1.0-2): DISCONNECT 0x82 and a
      # close the broker drains for a while, the socket still open
      :ok = :gen_tcp.send(socket, connect)
      assert %{type: :disconnect, reason_code: 0x82} = recv_packet(socket)

      # Reconnecting meanwhile is quick (no takeover deadline) and resumes
      started = System.monotonic_time(:millisecond)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: client_id,
          protocol_version: 5,
          clean_session: false,
          connect_properties: %{session_expiry_interval: 1},
          await_connect: true,
          handler: ForwardingHandler,
          handler_state: %{pid: self()}
        )

      assert_receive {:mqtt_event, :connected, %{session_present: true}}, 2_000
      assert System.monotonic_time(:millisecond) - started < 1_000

      # Past the old session's expiry, with the old connection long drained:
      # the session this connection resumed is still there, subscriptions and all
      Process.sleep(1_500)
      assert {:ok, 1} = MqttX.Server.deliver(name, "d/1", "still here", %{qos: 1})
      assert_receive {:mqtt_event, :message, {["d", "1"], "still here", _}}, 2_000

      MqttX.Client.disconnect(client)
      :gen_tcp.close(socket)
    end
  end
end
