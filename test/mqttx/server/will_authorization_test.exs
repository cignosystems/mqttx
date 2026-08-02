defmodule MqttX.Server.WillAuthorizationTest do
  @moduledoc """
  A Will message's topic, payload and retain flag come straight from the
  client's CONNECT and are never shown to `handle_connect/3,4`, so
  `handle_publish/4` is the only callback that can authorize them.

  Both Will paths used to write the retained entry *before* asking the handler
  and then discard its answer, so a peer that got past CONNECT could plant (or,
  with an empty payload, delete) a retained message on any topic its ACL
  forbids — `deliver_retained_messages/2` hands those to subscribers without
  consulting the handler again.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # Rejects every publish, exactly as a deployment's ACL would for a topic the
  # connecting peer has no rights to.
  defmodule RejectingHandler do
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:publish_rejected, MqttX.Topic.flatten(topic), payload})
      {:error, :unauthorized, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  defmodule AcceptingHandler do
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:publish_accepted, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp start_server(handler, opts) do
    port = free_port()

    {:ok, server} =
      MqttX.Server.start_link(handler, [notify: self()],
        port: port,
        transport: MqttX.Transport.ThousandIsland
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    Process.sleep(50)
    {server, port, Keyword.get(opts, :retained_table)}
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    p
  end

  defp connect_with_will(port, client_id, will, extra_props \\ %{}) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    {:ok, packet} =
      MqttX.Packet.Codec.encode(5, %{
        type: :connect,
        protocol_version: 5,
        client_id: client_id,
        clean_session: true,
        keep_alive: 0,
        username: nil,
        password: nil,
        will: will,
        properties: extra_props
      })

    :ok = :gen_tcp.send(socket, packet)
    {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)
    socket
  end

  # The listener's retained table is named for its port (see the transport
  # adapter's create_retained_table/1).
  defp retained_entries(port) do
    table = :"mqttx_retained_#{port}"

    case :ets.whereis(table) do
      :undefined -> []
      _ -> :ets.tab2list(table)
    end
  end

  describe "immediate Will (will_delay_interval = 0)" do
    test "a rejected retained Will is not written to the retained store" do
      {_server, port, _} = start_server(RejectingHandler, [])

      socket =
        connect_with_will(port, "attacker", %{
          topic: "tenant-a/device-1/cmd",
          payload: "reboot",
          qos: 0,
          retain: true,
          properties: %{}
        })

      # Ungraceful close fires the Will
      :gen_tcp.close(socket)

      assert_receive {:publish_rejected, "tenant-a/device-1/cmd", "reboot"}, 2_000
      # Give the store a moment to be (incorrectly) written
      Process.sleep(100)

      assert retained_entries(port) == [],
             "handler rejected the Will but it was still retained"
    end

    test "an accepted retained Will is written, so the gate is not just off" do
      {_server, port, _} = start_server(AcceptingHandler, [])

      socket =
        connect_with_will(port, "legit", %{
          topic: "sensors/room1/temp",
          payload: "21.5",
          qos: 0,
          retain: true,
          properties: %{}
        })

      :gen_tcp.close(socket)

      assert_receive {:publish_accepted, "sensors/room1/temp", "21.5"}, 2_000
      Process.sleep(100)

      entries = retained_entries(port)
      assert length(entries) == 1, "accepted retained Will should have been stored"
      assert elem(hd(entries), 0) == "sensors/room1/temp"
    end

    test "a rejected empty-payload Will cannot delete an existing retained message" do
      {_server, port, _} = start_server(RejectingHandler, [])

      # Seed a retained entry directly — the delete path is what we are testing
      table = :"mqttx_retained_#{port}"
      :ets.insert(table, {"fleet/config", ["fleet", "config"], "v1", 0, 0, nil})

      socket =
        connect_with_will(port, "attacker", %{
          topic: "fleet/config",
          payload: "",
          qos: 0,
          retain: true,
          properties: %{}
        })

      :gen_tcp.close(socket)

      assert_receive {:publish_rejected, "fleet/config", _}, 2_000
      Process.sleep(100)

      assert [{"fleet/config", _, "v1", _, _, _}] = retained_entries(port),
             "rejected Will deleted a retained message it was not authorized to touch"
    end
  end

  describe "delayed Will (will_delay_interval > 0)" do
    test "a rejected retained Will is not written to the retained store" do
      {_server, port, _} = start_server(RejectingHandler, [])

      socket =
        connect_with_will(
          port,
          "attacker-delayed",
          %{
            topic: "fleet/config",
            payload: "malicious",
            qos: 0,
            retain: true,
            properties: %{will_delay_interval: 1}
          },
          # a non-zero session expiry is what routes the Will through WillDelay
          %{session_expiry_interval: 30}
        )

      :gen_tcp.close(socket)

      # Fires ~1s later, from the shared WillDelay process
      assert_receive {:publish_rejected, "fleet/config", "malicious"}, 4_000
      Process.sleep(100)

      assert retained_entries(port) == [],
             "handler rejected the delayed Will but it was still retained"
    end
  end
end
