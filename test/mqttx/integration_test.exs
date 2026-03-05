defmodule MqttX.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # A test MQTT server handler that tracks events via an agent
  defmodule TestHandler do
    use MqttX.Server

    @impl true
    def init(opts) do
      %{agent: Keyword.fetch!(opts, :agent)}
    end

    @impl true
    def handle_connect(client_id, credentials, state) do
      Agent.update(state.agent, fn events ->
        [{:connect, client_id, credentials} | events]
      end)

      {:ok, state}
    end

    @impl true
    def handle_publish(topic, payload, opts, state) do
      # Normalize topic to a string for easier assertion matching
      topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic

      Agent.update(state.agent, fn events ->
        [{:publish, topic_str, payload, opts} | events]
      end)

      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state) do
      Agent.update(state.agent, fn events ->
        [{:subscribe, topics} | events]
      end)

      qos_list = Enum.map(topics, fn t -> Map.get(t, :qos, 0) end)
      {:ok, qos_list, state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      # Guard against agent being stopped before disconnect fires
      try do
        Agent.update(state.agent, fn events ->
          [{:disconnect, reason} | events]
        end)
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    @impl true
    def handle_unsubscribe(topics, state) do
      # Normalize topic lists to strings for easier assertions
      normalized =
        Enum.map(topics, fn
          t when is_list(t) -> Enum.join(t, "/")
          t -> t
        end)

      Agent.update(state.agent, fn events ->
        [{:unsubscribe, normalized} | events]
      end)

      {:ok, state}
    end
  end

  # A test handler that supports server disconnect via handle_info
  defmodule DisconnectHandler do
    use MqttX.Server

    @impl true
    def init(opts) do
      %{agent: Keyword.fetch!(opts, :agent), test_pid: Keyword.get(opts, :test_pid)}
    end

    @impl true
    def handle_connect(client_id, _credentials, state) do
      # Send the transport pid to the test so it can call MqttX.Server.disconnect/3
      if state.test_pid, do: send(state.test_pid, {:transport_pid, self()})

      Agent.update(state.agent, fn events ->
        [{:connect, client_id} | events]
      end)

      {:ok, state}
    end

    @impl true
    def handle_publish(topic, _payload, _opts, state) do
      topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic

      # Disconnect client if they publish to "forbidden" topic
      if topic_str == "forbidden/topic" do
        {:disconnect, 0x98, state}
      else
        {:ok, state}
      end
    end

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      try do
        Agent.update(state.agent, fn events ->
          [{:disconnect, reason} | events]
        end)
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    @impl true
    def handle_info({:kick_client, reason_code}, state) do
      {:disconnect, reason_code, state}
    end

    def handle_info(_msg, state) do
      {:ok, state}
    end
  end

  # A test handler that tracks session expiry
  defmodule SessionExpiryHandler do
    use MqttX.Server

    @impl true
    def init(opts) do
      %{agent: Keyword.fetch!(opts, :agent)}
    end

    @impl true
    def handle_connect(client_id, _credentials, state) do
      Agent.update(state.agent, fn events ->
        [{:connect, client_id} | events]
      end)

      {:ok, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      try do
        Agent.update(state.agent, fn events ->
          [{:disconnect, reason} | events]
        end)
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    @impl true
    def handle_session_expired(client_id, state) do
      try do
        Agent.update(state.agent, fn events ->
          [{:session_expired, client_id} | events]
        end)
      catch
        :exit, _ -> :ok
      end

      :ok
    end
  end

  # A test handler that rejects connections
  defmodule RejectHandler do
    use MqttX.Server

    @impl true
    def init(_opts), do: %{}

    @impl true
    def handle_connect(_client_id, _credentials, state) do
      {:error, 0x86, state}
    end

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn _ -> 0 end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  # Client handler to receive messages
  defmodule ClientHandler do
    def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
      # Normalize topic to string
      topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic

      Agent.update(state.agent, fn events ->
        [{:message, topic_str, payload} | events]
      end)

      state
    end

    def handle_mqtt_event(:connected, _data, state) do
      Agent.update(state.agent, fn events ->
        [:connected | events]
      end)

      state
    end

    def handle_mqtt_event(:disconnected, reason, state) do
      Agent.update(state.agent, fn events ->
        [{:disconnected, reason} | events]
      end)

      state
    end
  end

  defp start_server(handler, handler_opts, opts \\ []) do
    port = Keyword.get(opts, :port, get_free_port())
    transport_opts = Keyword.merge([port: port, transport: MqttX.Transport.ThousandIsland], opts)

    {:ok, server_pid} =
      MqttX.Server.start_link(handler, handler_opts, transport_opts)

    # Give server time to start listening
    Process.sleep(50)

    {server_pid, port}
  end

  defp encode_packet!(version, packet) do
    {:ok, data} = MqttX.Packet.Codec.encode(version, packet)
    data
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_for_events(agent, count, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(agent, count, deadline)
  end

  defp wait_loop(agent, count, deadline) do
    events = Agent.get(agent, & &1)

    if length(events) >= count do
      events
    else
      if System.monotonic_time(:millisecond) > deadline do
        events
      else
        Process.sleep(25)
        wait_loop(agent, count, deadline)
      end
    end
  end

  describe "client-server connect" do
    test "client connects to server successfully (MQTT 3.1.1)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "integration-test-1",
          protocol_version: 4,
          keepalive: 30
        )

      Process.sleep(200)

      assert MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:connect, "integration-test-1", _}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client connects to server successfully (MQTT 5.0)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "integration-mqtt5",
          protocol_version: 5,
          keepalive: 30
        )

      Process.sleep(200)

      assert MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:connect, "integration-mqtt5", _}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client receives rejection from server" do
      {server_pid, port} = start_server(RejectHandler, [])

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "rejected-client",
          protocol_version: 4
        )

      Process.sleep(300)

      refute MqttX.Client.connected?(client)

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
    end
  end

  describe "publish flow" do
    test "client publishes QoS 0 message to server" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "pub-qos0",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.publish(client, "test/topic", "hello world")

      events = wait_for_events(agent, 2)

      assert Enum.any?(events, &match?({:publish, "test/topic", "hello world", %{qos: 0}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client publishes QoS 1 message to server" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "pub-qos1",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.publish(client, "test/qos1", "qos1 payload", qos: 1)

      events = wait_for_events(agent, 2)

      assert Enum.any?(events, &match?({:publish, "test/qos1", "qos1 payload", %{qos: 1}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client publishes QoS 0 message with MQTT 5.0" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "pub-mqtt5-qos0",
          protocol_version: 5
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.publish(client, "mqtt5/topic", "mqtt5 payload")

      events = wait_for_events(agent, 2)

      assert Enum.any?(events, &match?({:publish, "mqtt5/topic", "mqtt5 payload", _}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client publishes QoS 2 message to server" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "pub-qos2",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.publish(client, "test/qos2", "qos2 payload", qos: 2)

      events = wait_for_events(agent, 2, 3000)

      assert Enum.any?(events, &match?({:publish, "test/qos2", "qos2 payload", %{qos: 2}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "subscribe flow" do
    test "client subscribes to topics" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "sub-test",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.subscribe(client, "test/sub/#", qos: 1)

      events = wait_for_events(agent, 2)

      # Topics are decoded/normalized — just verify a subscribe event was received
      assert Enum.any?(events, &match?({:subscribe, _}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "client unsubscribes from topics" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "unsub-test",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.subscribe(client, "unsub/topic")
      Process.sleep(100)
      :ok = MqttX.Client.unsubscribe(client, "unsub/topic")

      events = wait_for_events(agent, 3)

      assert Enum.any?(events, &match?({:unsubscribe, ["unsub/topic"]}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "disconnect flow" do
    test "client disconnects gracefully" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "disconnect-test",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      MqttX.Client.disconnect(client)
      Process.sleep(200)

      events = Agent.get(agent, & &1)

      assert Enum.any?(events, &match?({:disconnect, :normal}, &1))

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "keepalive (ping/pong)" do
    test "client stays connected with keepalive pings" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "keepalive-test",
          protocol_version: 4,
          keepalive: 1
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # Wait long enough for at least one keepalive cycle
      Process.sleep(1500)

      assert MqttX.Client.connected?(client)

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "multiple clients" do
    test "multiple clients connect to same server" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      clients =
        for i <- 1..5 do
          {:ok, client} =
            MqttX.Client.connect(
              host: "127.0.0.1",
              port: port,
              client_id: "multi-#{i}",
              protocol_version: 4
            )

          client
        end

      Process.sleep(500)

      Enum.each(clients, fn client ->
        assert MqttX.Client.connected?(client)
      end)

      events = Agent.get(agent, & &1)
      connect_events = Enum.filter(events, &match?({:connect, _, _}, &1))
      assert length(connect_events) == 5

      Enum.each(clients, fn client ->
        GenServer.stop(client, :normal, 1000)
      end)

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "supervised connections integration" do
    test "supervised client connects to server" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect_supervised(
          host: "127.0.0.1",
          port: port,
          client_id: "supervised-int-test",
          protocol_version: 4
        )

      Process.sleep(200)

      assert MqttX.Client.connected?(client)

      # Should be findable via whereis
      {pid, _meta} = MqttX.Client.whereis("supervised-int-test")
      assert pid == client

      # Should appear in list
      connections = MqttX.Client.list()
      assert Enum.any?(connections, fn {id, _pid, _meta} -> id == "supervised-int-test" end)

      MqttX.Client.Supervisor.stop_child(client)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "rate limiting integration" do
    test "server rate limits connections" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {server_pid, port} =
        start_server(TestHandler, [agent: agent],
          port: get_free_port(),
          rate_limit: [max_connections: 2, interval: 60_000]
        )

      # First two connections should succeed
      {:ok, client1} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "rate-1",
          protocol_version: 4
        )

      {:ok, client2} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "rate-2",
          protocol_version: 4
        )

      Process.sleep(300)

      assert MqttX.Client.connected?(client1)
      assert MqttX.Client.connected?(client2)

      # Third connection should be rate limited (closed immediately)
      {:ok, client3} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "rate-3",
          protocol_version: 4
        )

      Process.sleep(500)

      refute MqttX.Client.connected?(client3)

      GenServer.stop(client1, :normal, 1000)
      GenServer.stop(client2, :normal, 1000)
      GenServer.stop(client3, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "retained messages" do
    test "client receives retained message on subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client_agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      # First client publishes a retained message
      {:ok, pub_client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "retained-publisher",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(pub_client)

      :ok = MqttX.Client.publish(pub_client, "retained/topic", "retained payload", retain: true)
      Process.sleep(200)

      # Second client subscribes and should get the retained message
      {:ok, sub_client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "retained-subscriber",
          protocol_version: 4,
          handler: ClientHandler,
          handler_state: %{agent: client_agent}
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(sub_client)

      :ok = MqttX.Client.subscribe(sub_client, "retained/topic")

      # Wait for retained message delivery
      events = wait_for_events(client_agent, 2, 3000)

      assert Enum.any?(events, &match?({:message, "retained/topic", "retained payload"}, &1))

      GenServer.stop(pub_client, :normal, 1000)
      GenServer.stop(sub_client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
      Agent.stop(client_agent)
    end
  end

  describe "server telemetry events" do
    test "server emits connect start/stop telemetry" do
      test_pid = self()
      handler_id = "server-telem-connect-#{System.unique_integer()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [
          [:mqttx, :server, :client_connect, :start],
          [:mqttx, :server, :client_connect, :stop]
        ],
        handler_fn,
        nil
      )

      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "telem-connect-test",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      assert_received {:telemetry, [:mqttx, :server, :client_connect, :start], _,
                       %{client_id: "telem-connect-test"}}

      assert_received {:telemetry, [:mqttx, :server, :client_connect, :stop], %{duration: _}, _}

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
      :telemetry.detach(handler_id)
    end

    test "server emits connect exception telemetry on rejection" do
      test_pid = self()
      handler_id = "server-telem-reject-#{System.unique_integer()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [[:mqttx, :server, :client_connect, :exception]],
        handler_fn,
        nil
      )

      {server_pid, port} = start_server(RejectHandler, [])

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "telem-reject-test",
          protocol_version: 5
        )

      Process.sleep(500)
      refute MqttX.Client.connected?(client)

      assert_received {:telemetry, [:mqttx, :server, :client_connect, :exception], %{duration: _},
                       _}

      Process.unlink(client)
      Process.exit(client, :kill)
      ThousandIsland.stop(server_pid)
      :telemetry.detach(handler_id)
    end

    test "server emits publish and subscribe telemetry" do
      test_pid = self()
      handler_id = "server-telem-pubsub-#{System.unique_integer()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [
          [:mqttx, :server, :publish],
          [:mqttx, :server, :subscribe]
        ],
        handler_fn,
        nil
      )

      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "telem-pubsub-test",
          protocol_version: 4
        )

      Process.sleep(200)

      :ok = MqttX.Client.subscribe(client, "telem/topic", qos: 1)
      Process.sleep(100)

      assert_received {:telemetry, [:mqttx, :server, :subscribe], _,
                       %{client_id: "telem-pubsub-test"}}

      :ok = MqttX.Client.publish(client, "telem/topic", "telem payload", qos: 0)
      Process.sleep(100)

      assert_received {:telemetry, [:mqttx, :server, :publish], %{payload_size: _},
                       %{client_id: "telem-pubsub-test"}}

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
      :telemetry.detach(handler_id)
    end

    test "server emits client disconnect telemetry" do
      test_pid = self()
      handler_id = "server-telem-disc-#{System.unique_integer()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [[:mqttx, :server, :client_disconnect]],
        handler_fn,
        nil
      )

      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "telem-disc-test",
          protocol_version: 4
        )

      Process.sleep(200)
      MqttX.Client.disconnect(client)
      Process.sleep(500)

      assert_received {:telemetry, [:mqttx, :server, :client_disconnect], _,
                       %{client_id: "telem-disc-test"}}

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
      :telemetry.detach(handler_id)
    end
  end

  describe "flow control" do
    test "flow_control error returned when max_inflight exceeded" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "flow-control-test",
          protocol_version: 5,
          max_inflight: 1
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # First QoS 1 publish — should succeed and occupy the single inflight slot
      assert :ok = MqttX.Client.publish(client, "flow/topic", "msg1", qos: 1)

      # Immediately try second — should fail since PUBACK hasn't arrived yet
      # and max_inflight is 1
      result = MqttX.Client.publish(client, "flow/topic", "msg2", qos: 1)
      assert result == {:error, :flow_control}

      # After PUBACK arrives, next publish should work
      Process.sleep(500)
      assert :ok = MqttX.Client.publish(client, "flow/topic", "msg3", qos: 1)

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "connect_supervised against local server" do
    test "supervised client connects and appears in registry" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect_supervised(
          host: "127.0.0.1",
          port: port,
          client_id: "supervised-local-test",
          protocol_version: 4
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # Verify it appears in registry
      assert {pid, _meta} = MqttX.Client.whereis("supervised-local-test")
      assert pid == client

      # Verify list includes it
      clients = MqttX.Client.list()
      assert Enum.any?(clients, fn {id, _, _} -> id == "supervised-local-test" end)

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "request/4 helper" do
    test "request subscribes to response topic and publishes with correlation data" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "request-test",
          protocol_version: 5
        )

      Process.sleep(200)

      {:ok, correlation_data} =
        MqttX.Client.request(client, "api/users", "get_user",
          response_topic: "api/responses/request-test",
          qos: 1
        )

      assert is_binary(correlation_data)
      assert byte_size(correlation_data) == 16

      Process.sleep(200)

      # Server should have received both a subscribe and a publish
      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:subscribe, _}, &1))
      assert Enum.any?(events, &match?({:publish, "api/users", "get_user", _}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "server-initiated disconnect" do
    test "server disconnects client via MqttX.Server.disconnect/3" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      test_pid = self()

      {server_pid, port} =
        start_server(DisconnectHandler, agent: agent, test_pid: test_pid)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "server-disconnect-test",
          protocol_version: 5,
          keepalive: 30
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # Get the transport pid
      assert_receive {:transport_pid, transport_pid}

      # Server kicks the client
      MqttX.Server.disconnect(transport_pid, 0x98)
      Process.sleep(300)

      refute MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:disconnect, {:server_disconnect, 0x98}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "handler returns {:disconnect, reason_code, state} from handle_publish" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {server_pid, port} =
        start_server(DisconnectHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "disconnect-publish-test",
          protocol_version: 5,
          keepalive: 30
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # Publishing to forbidden topic triggers disconnect
      :ok = MqttX.Client.publish(client, "forbidden/topic", "bad data")
      Process.sleep(500)

      refute MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:disconnect, {:server_disconnect, 0x98}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "handler returns {:disconnect, ...} from handle_info" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      test_pid = self()

      {server_pid, port} =
        start_server(DisconnectHandler, agent: agent, test_pid: test_pid)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "disconnect-info-test",
          protocol_version: 5,
          keepalive: 30
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      assert_receive {:transport_pid, transport_pid}

      # Send a message to the transport that triggers {:disconnect, ...} from handle_info
      send(transport_pid, {:kick_client, 0x89})
      Process.sleep(300)

      refute MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:disconnect, {:server_disconnect, 0x89}}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "server keepalive timeout" do
    test "server disconnects client that stops sending packets within 1.5x keepalive" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      # Connect with very short keepalive (1 second) but no client-side keepalive pings
      # We use a raw TCP connection to avoid the client sending PINGREQs automatically
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send CONNECT with keepalive=1
      connect_packet =
        encode_packet!(4, %{
          type: :connect,
          protocol_version: 4,
          client_id: "keepalive-timeout-test",
          clean_session: true,
          keep_alive: 1,
          username: nil,
          password: nil,
          will: nil,
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      # Read CONNACK
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      # Wait for 1.5x keepalive + margin (should timeout at ~1500ms)
      Process.sleep(2000)

      # Connection should be closed by server
      result = :gen_tcp.recv(socket, 0, 500)
      assert result == {:error, :closed} or match?({:error, _}, result)

      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:disconnect, :keepalive_timeout}, &1))

      :gen_tcp.close(socket)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "server does not timeout client that sends keepalive pings" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "keepalive-active-test",
          protocol_version: 4,
          keepalive: 1
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      # Wait for 3 seconds — client should stay alive due to keepalive pings
      Process.sleep(3000)

      assert MqttX.Client.connected?(client)

      events = Agent.get(agent, & &1)
      refute Enum.any?(events, &match?({:disconnect, :keepalive_timeout}, &1))

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "server resets keepalive timer on publish" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with keepalive=2
      connect_packet =
        encode_packet!(4, %{
          type: :connect,
          protocol_version: 4,
          client_id: "keepalive-reset-test",
          clean_session: true,
          keep_alive: 2,
          username: nil,
          password: nil,
          will: nil,
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      # Send a publish at 2 seconds (before 3s timeout)
      Process.sleep(2000)

      publish_packet =
        encode_packet!(4, %{
          type: :publish,
          topic: "test/topic",
          payload: "keepalive reset",
          qos: 0,
          retain: false,
          dup: false,
          packet_id: nil,
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, publish_packet)

      # Wait 2 more seconds — should still be alive (timer was reset)
      Process.sleep(2000)

      # Send another publish to check connection is still open
      result = :gen_tcp.send(socket, publish_packet)
      assert result == :ok

      :gen_tcp.close(socket)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "will delay interval" do
    test "will message published immediately when delay_interval is 0" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with will message (no delay)
      connect_packet =
        encode_packet!(4, %{
          type: :connect,
          protocol_version: 4,
          client_id: "will-nodelay-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: %{
            topic: "will/immediate",
            payload: "client gone",
            qos: 0,
            retain: false,
            properties: %{}
          },
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Kill connection without DISCONNECT (ungraceful)
      :gen_tcp.close(socket)

      # Will should be published immediately
      Process.sleep(500)

      events = Agent.get(agent, & &1)

      assert Enum.any?(events, fn
               {:publish, topic, "client gone", _} ->
                 topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic
                 topic_str == "will/immediate"

               _ ->
                 false
             end)

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "will message delayed when will_delay_interval > 0 (MQTT 5.0)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with MQTT 5.0 and will_delay_interval=2
      connect_packet =
        encode_packet!(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: "will-delay-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: %{
            topic: "will/delayed",
            payload: "delayed goodbye",
            qos: 0,
            retain: false,
            properties: %{will_delay_interval: 2}
          },
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Kill connection without DISCONNECT
      :gen_tcp.close(socket)

      # Will should NOT be published immediately
      Process.sleep(500)
      events_early = Agent.get(agent, & &1)

      refute Enum.any?(events_early, fn
               {:publish, topic, "delayed goodbye", _} ->
                 topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic
                 topic_str == "will/delayed"

               _ ->
                 false
             end)

      # Wait for delay to expire (2 seconds + margin)
      Process.sleep(2500)
      events_late = Agent.get(agent, & &1)

      assert Enum.any?(events_late, fn
               {:publish, topic, "delayed goodbye", _} ->
                 topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic
                 topic_str == "will/delayed"

               _ ->
                 false
             end)

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "session expiry" do
    test "handle_session_expired called when session_expiry_interval expires" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(SessionExpiryHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with MQTT 5.0 and session_expiry_interval=1
      connect_packet =
        encode_packet!(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: "session-expiry-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: nil,
          properties: %{session_expiry_interval: 1}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Disconnect ungracefully
      :gen_tcp.close(socket)

      # Session should not have expired yet
      Process.sleep(500)
      events_early = Agent.get(agent, & &1)
      refute Enum.any?(events_early, &match?({:session_expired, "session-expiry-test"}, &1))

      # Wait for session expiry (1 second + margin)
      Process.sleep(1500)
      events_late = Agent.get(agent, & &1)
      assert Enum.any?(events_late, &match?({:session_expired, "session-expiry-test"}, &1))

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "handle_session_expired called immediately when session_expiry_interval is 0" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(SessionExpiryHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with MQTT 5.0 and session_expiry_interval=0
      connect_packet =
        encode_packet!(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: "session-immediate-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: nil,
          properties: %{session_expiry_interval: 0}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Disconnect ungracefully
      :gen_tcp.close(socket)

      # Session should expire immediately
      Process.sleep(500)
      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:session_expired, "session-immediate-test"}, &1))

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "handle_session_expired not called when session_expiry_interval is 0xFFFFFFFF (never expire)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(SessionExpiryHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with MQTT 5.0 and session_expiry_interval=0xFFFFFFFF (never expire)
      connect_packet =
        encode_packet!(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: "session-never-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: nil,
          properties: %{session_expiry_interval: 0xFFFFFFFF}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Disconnect ungracefully
      :gen_tcp.close(socket)

      Process.sleep(1000)
      events = Agent.get(agent, & &1)
      refute Enum.any?(events, &match?({:session_expired, _}, &1))

      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end

    test "session expiry on graceful disconnect" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(SessionExpiryHandler, agent: agent)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Connect with MQTT 5.0 and session_expiry_interval=1
      connect_packet =
        encode_packet!(5, %{
          type: :connect,
          protocol_version: 5,
          client_id: "session-graceful-test",
          clean_session: true,
          keep_alive: 0,
          username: nil,
          password: nil,
          will: nil,
          properties: %{session_expiry_interval: 1}
        })

      :ok = :gen_tcp.send(socket, connect_packet)
      {:ok, _connack} = :gen_tcp.recv(socket, 0, 2000)

      Process.sleep(100)

      # Send graceful DISCONNECT
      disconnect_packet =
        encode_packet!(5, %{
          type: :disconnect,
          reason_code: 0,
          properties: %{}
        })

      :ok = :gen_tcp.send(socket, disconnect_packet)

      # Wait for session expiry
      Process.sleep(2000)
      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:session_expired, "session-graceful-test"}, &1))

      :gen_tcp.close(socket)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end

  describe "shared subscriptions" do
    test "client subscribes to $share/ topic filter" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {server_pid, port} = start_server(TestHandler, agent: agent)

      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "shared-sub-client",
          protocol_version: 5
        )

      Process.sleep(200)
      assert MqttX.Client.connected?(client)

      :ok = MqttX.Client.subscribe(client, "$share/workers/jobs/#", qos: 1)

      events = wait_for_events(agent, 2)

      assert Enum.any?(events, fn
               {:subscribe, topics} ->
                 Enum.any?(topics, fn t ->
                   topic = if is_list(t.topic), do: Enum.join(t.topic, "/"), else: t.topic
                   String.starts_with?(topic, "$share/")
                 end)

               _ ->
                 false
             end)

      GenServer.stop(client, :normal, 1000)
      ThousandIsland.stop(server_pid)
      Agent.stop(agent)
    end
  end
end
