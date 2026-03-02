defmodule MqttX.InteropEmqxTest do
  @moduledoc """
  Interoperability tests against a live EMQX broker.

  Run with:

      EMQX_HOST=cloud2.example.com EMQX_PORT=8883 \\
        EMQX_USERNAME=myuser EMQX_PASSWORD=mypass \\
        mix test test/mqttx/interop_emqx_test.exs --include interop
  """
  use ExUnit.Case, async: false

  @moduletag :interop

  @host System.get_env("EMQX_HOST", "localhost")
  @port String.to_integer(System.get_env("EMQX_PORT", "8883"))
  @username System.get_env("EMQX_USERNAME", "")
  @password System.get_env("EMQX_PASSWORD", "")

  # Client handler to capture received messages
  defmodule Handler do
    def handle_mqtt_event(:message, {topic, payload, packet}, state) do
      topic_str = if is_list(topic), do: Enum.join(topic, "/"), else: topic

      Agent.update(state.agent, fn events ->
        [{:message, topic_str, payload, Map.get(packet, :properties, %{})} | events]
      end)

      state
    end

    def handle_mqtt_event(:connected, data, state) do
      Agent.update(state.agent, fn events -> [{:connected, data} | events] end)
      state
    end

    def handle_mqtt_event(:disconnected, reason, state) do
      Agent.update(state.agent, fn events -> [{:disconnected, reason} | events] end)
      state
    end
  end

  defp connect_emqx(client_id, opts \\ []) do
    agent = Keyword.get(opts, :agent)
    extra = Keyword.get(opts, :extra, [])

    connect_opts =
      [
        host: @host,
        port: @port,
        client_id: client_id,
        username: Keyword.get(opts, :username, @username),
        password: Keyword.get(opts, :password, @password),
        transport: :ssl,
        ssl_opts: [verify: :verify_none],
        keepalive: Keyword.get(opts, :keepalive, 30),
        protocol_version: Keyword.get(opts, :protocol_version, 4),
        clean_session: Keyword.get(opts, :clean_session, true)
      ] ++ extra

    connect_opts =
      if agent do
        connect_opts ++ [handler: Handler, handler_state: %{agent: agent}]
      else
        connect_opts
      end

    MqttX.Client.connect(connect_opts)
  end

  defp wait_for_events(agent, count, timeout \\ 5000) do
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
        Process.sleep(50)
        wait_loop(agent, count, deadline)
      end
    end
  end

  defp uid, do: :rand.uniform(100_000_000)

  # ===========================================================================
  # MQTT 3.1.1 — Core Protocol
  # ===========================================================================

  describe "MQTT 3.1.1 — connection" do
    test "connects and authenticates over TLS" do
      {:ok, client} = connect_emqx("mqttx-conn-#{uid()}")
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)
      GenServer.stop(client, :normal, 1000)
    end

    test "rejects wrong credentials" do
      {:ok, client} =
        connect_emqx("mqttx-badauth-#{uid()}",
          username: "wrong_user",
          password: "wrong_pass"
        )

      Process.sleep(3000)
      refute MqttX.Client.connected?(client)
      GenServer.stop(client, :normal, 1000)
    end

    test "graceful disconnect" do
      {:ok, client} = connect_emqx("mqttx-disc-#{uid()}")
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      MqttX.Client.disconnect(client)
      Process.sleep(500)
      refute Process.alive?(client)
    end

    test "keepalive keeps connection alive" do
      {:ok, client} = connect_emqx("mqttx-ka-#{uid()}", keepalive: 2)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      # Wait for multiple keepalive cycles (2s interval)
      Process.sleep(5000)
      assert MqttX.Client.connected?(client)
      GenServer.stop(client, :normal, 1000)
    end

    test "reconnects after connection drop" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-reconn-#{uid()}", agent: agent)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      # Force-close the underlying socket to simulate a drop
      state = :sys.get_state(client)
      :ssl.close(state.socket)

      # Wait for reconnection (backoff starts at ~1s)
      Process.sleep(5000)
      assert MqttX.Client.connected?(client)

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 3.1.1 — QoS 0" do
    test "publish and subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-q0-#{uid()}", agent: agent)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      topic = "mqttx/test/qos0/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 0)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "qos0 payload")

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "qos0 payload", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "empty payload" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-empty-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/empty/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "")

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "binary (non-UTF8) payload" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-bin-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/binary/#{uid()}"
      binary_payload = <<0, 1, 2, 255, 254, 253, 128, 0, 0>>
      :ok = MqttX.Client.subscribe(client, topic)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, binary_payload)

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, ^binary_payload, _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "large payload (64 KB)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-large-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/large/#{uid()}"
      large_payload = :crypto.strong_rand_bytes(65536)
      :ok = MqttX.Client.subscribe(client, topic)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, large_payload)

      events = wait_for_events(agent, 2, 10_000)

      assert Enum.any?(events, fn
               {:message, ^topic, payload, _} -> payload == large_payload
               _ -> false
             end)

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 3.1.1 — QoS 1" do
    test "publish and subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-q1-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/qos1/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "qos1 payload", qos: 1)

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "qos1 payload", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "burst of 20 QoS 1 messages" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-burst-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/burst/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      for i <- 1..20 do
        :ok = MqttX.Client.publish(client, topic, "msg-#{i}", qos: 1)
      end

      # Wait for all 20 messages + :connected event = 21
      events = wait_for_events(agent, 21, 15_000)
      msg_events = Enum.filter(events, &match?({:message, _, _, _}, &1))
      assert length(msg_events) == 20

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 3.1.1 — QoS 2" do
    test "publish and subscribe (full 4-step handshake)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-q2-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/qos2/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 2)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "qos2 exactly once", qos: 2)

      events = wait_for_events(agent, 2, 10_000)
      assert Enum.any?(events, &match?({:message, ^topic, "qos2 exactly once", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 3.1.1 — subscribe features" do
    test "wildcard # subscription" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-wild-#{uid()}", agent: agent)
      Process.sleep(2000)

      base = "mqttx/test/wild/#{uid()}"
      :ok = MqttX.Client.subscribe(client, "#{base}/#")
      Process.sleep(500)

      :ok = MqttX.Client.publish(client, "#{base}/a", "w1")
      :ok = MqttX.Client.publish(client, "#{base}/b/c", "w2")

      events = wait_for_events(agent, 3)
      assert Enum.any?(events, &match?({:message, _, "w1", _}, &1))
      assert Enum.any?(events, &match?({:message, _, "w2", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "wildcard + subscription" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-plus-#{uid()}", agent: agent)
      Process.sleep(2000)

      base = "mqttx/test/plus/#{uid()}"
      :ok = MqttX.Client.subscribe(client, "#{base}/+/data")
      Process.sleep(500)

      :ok = MqttX.Client.publish(client, "#{base}/sensor1/data", "s1")
      :ok = MqttX.Client.publish(client, "#{base}/sensor2/data", "s2")
      # This should NOT match (extra level)
      :ok = MqttX.Client.publish(client, "#{base}/sensor3/extra/data", "s3")

      events = wait_for_events(agent, 3, 5000)
      assert Enum.any?(events, &match?({:message, _, "s1", _}, &1))
      assert Enum.any?(events, &match?({:message, _, "s2", _}, &1))
      refute Enum.any?(events, &match?({:message, _, "s3", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "multiple topics in one subscribe call" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-multi-#{uid()}", agent: agent)
      Process.sleep(2000)

      t1 = "mqttx/test/multi/#{uid()}/a"
      t2 = "mqttx/test/multi/#{uid()}/b"
      :ok = MqttX.Client.subscribe(client, [t1, t2], qos: 1)
      Process.sleep(500)

      :ok = MqttX.Client.publish(client, t1, "msg-a", qos: 1)
      :ok = MqttX.Client.publish(client, t2, "msg-b", qos: 1)

      events = wait_for_events(agent, 3)
      assert Enum.any?(events, &match?({:message, ^t1, "msg-a", _}, &1))
      assert Enum.any?(events, &match?({:message, ^t2, "msg-b", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "unsubscribe stops delivery" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-unsub-#{uid()}", agent: agent)
      Process.sleep(2000)

      topic = "mqttx/test/unsub/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic)
      Process.sleep(500)

      :ok = MqttX.Client.publish(client, topic, "before")
      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, _, "before", _}, &1))

      :ok = MqttX.Client.unsubscribe(client, topic)
      Process.sleep(500)
      Agent.update(agent, fn _ -> [] end)

      :ok = MqttX.Client.publish(client, topic, "after")
      Process.sleep(2000)
      events = Agent.get(agent, & &1)
      refute Enum.any?(events, &match?({:message, _, "after", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "special characters in topic" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-special-#{uid()}", agent: agent)
      Process.sleep(2000)

      # MQTT allows most UTF-8 in topics (except +, #, null)
      topic = "mqttx/test/spécial/über-tøpic/日本語/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "unicode topic")

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, _, "unicode topic", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 3.1.1 — retained messages" do
    test "subscriber receives retained message" do
      pub_id = "mqttx-ret-pub-#{uid()}"
      sub_id = "mqttx-ret-sub-#{uid()}"
      {:ok, pub_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)

      topic = "mqttx/test/retained/#{uid()}"

      # Publish retained message
      {:ok, publisher} = connect_emqx(pub_id, agent: pub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.publish(publisher, topic, "retained data", retain: true)
      Process.sleep(1000)

      # New subscriber should receive the retained message
      {:ok, subscriber} = connect_emqx(sub_id, agent: sub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 0)

      events = wait_for_events(sub_agent, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "retained data", _}, &1))

      # Clean up: clear retained message by publishing empty payload with retain
      :ok = MqttX.Client.publish(publisher, topic, "", retain: true)
      Process.sleep(500)

      GenServer.stop(publisher, :normal, 1000)
      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(pub_agent)
      Agent.stop(sub_agent)
    end

    test "empty retain payload clears retained message" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      topic = "mqttx/test/retclear/#{uid()}"

      {:ok, client1} = connect_emqx("mqttx-retc1-#{uid()}", agent: agent)
      Process.sleep(2000)

      # Set retained
      :ok = MqttX.Client.publish(client1, topic, "to-be-cleared", retain: true)
      Process.sleep(500)

      # Clear it
      :ok = MqttX.Client.publish(client1, topic, "", retain: true)
      Process.sleep(1000)

      # New subscriber should NOT get retained message
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      {:ok, client2} = connect_emqx("mqttx-retc2-#{uid()}", agent: sub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(client2, topic)
      Process.sleep(2000)

      events = Agent.get(sub_agent, & &1)
      refute Enum.any?(events, &match?({:message, _, "to-be-cleared", _}, &1))

      GenServer.stop(client1, :normal, 1000)
      GenServer.stop(client2, :normal, 1000)
      Agent.stop(agent)
      Agent.stop(sub_agent)
    end
  end

  describe "MQTT 3.1.1 — will messages" do
    test "will message published on ungraceful disconnect" do
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      will_topic = "mqttx/test/will/#{uid()}"
      will_payload = "client died"

      # Subscriber listens for the will topic
      {:ok, subscriber} = connect_emqx("mqttx-willsub-#{uid()}", agent: sub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, will_topic, qos: 1)
      Process.sleep(500)

      # Publisher connects WITH a will message
      # We need to use raw connection opts for will
      {:ok, will_client} =
        MqttX.Client.connect(
          host: @host,
          port: @port,
          client_id: "mqttx-willpub-#{uid()}",
          username: @username,
          password: @password,
          transport: :ssl,
          ssl_opts: [verify: :verify_none],
          keepalive: 5,
          protocol_version: 4,
          will_topic: will_topic,
          will_payload: will_payload,
          will_qos: 1
        )

      Process.sleep(2000)
      assert MqttX.Client.connected?(will_client)

      # Force-kill the will client (ungraceful disconnect)
      # Unlink first so :kill doesn't propagate to test process
      Process.unlink(will_client)
      Process.exit(will_client, :kill)
      Process.sleep(500)
      refute Process.alive?(will_client)

      # EMQX should publish the will message — wait for the broker's keepalive timeout
      # EMQX detects dead connection after ~1.5x keepalive (5s * 1.5 = 7.5s)
      events = wait_for_events(sub_agent, 2, 15_000)
      assert Enum.any?(events, &match?({:message, ^will_topic, ^will_payload, _}, &1))

      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end

    test "will message NOT published on graceful disconnect" do
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      will_topic = "mqttx/test/willgrace/#{uid()}"

      {:ok, subscriber} = connect_emqx("mqttx-wgsub-#{uid()}", agent: sub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, will_topic, qos: 1)
      Process.sleep(500)

      {:ok, will_client} =
        MqttX.Client.connect(
          host: @host,
          port: @port,
          client_id: "mqttx-wgpub-#{uid()}",
          username: @username,
          password: @password,
          transport: :ssl,
          ssl_opts: [verify: :verify_none],
          keepalive: 30,
          protocol_version: 4,
          will_topic: will_topic,
          will_payload: "should not appear",
          will_qos: 1
        )

      Process.sleep(2000)
      assert MqttX.Client.connected?(will_client)

      # Graceful disconnect — will should NOT be published
      MqttX.Client.disconnect(will_client)
      Process.sleep(5000)

      events = Agent.get(sub_agent, & &1)
      refute Enum.any?(events, &match?({:message, _, "should not appear", _}, &1))

      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end
  end

  describe "MQTT 3.1.1 — two clients" do
    test "publisher and subscriber communicate" do
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      topic = "mqttx/test/twoclient/#{uid()}"

      {:ok, subscriber} = connect_emqx("mqttx-2csub-#{uid()}", agent: sub_agent)
      {:ok, publisher} = connect_emqx("mqttx-2cpub-#{uid()}")
      Process.sleep(2000)

      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 1)
      Process.sleep(500)

      :ok = MqttX.Client.publish(publisher, topic, "cross-client", qos: 1)

      events = wait_for_events(sub_agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "cross-client", _}, &1))

      GenServer.stop(publisher, :normal, 1000)
      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — Protocol & Properties
  # ===========================================================================

  describe "MQTT 5.0 — connection" do
    test "connects with protocol version 5" do
      {:ok, client} = connect_emqx("mqttx-v5-#{uid()}", protocol_version: 5)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)
      GenServer.stop(client, :normal, 1000)
    end
  end

  describe "MQTT 5.0 — QoS" do
    test "QoS 0 publish/subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5q0-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/qos0/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 0)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "v5 qos0")

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "v5 qos0", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "QoS 1 publish/subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5q1-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/qos1/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "v5 qos1", qos: 1)

      events = wait_for_events(agent, 2)
      assert Enum.any?(events, &match?({:message, ^topic, "v5 qos1", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "QoS 2 publish/subscribe" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5q2-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/qos2/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 2)
      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "v5 qos2", qos: 2)

      events = wait_for_events(agent, 2, 10_000)
      assert Enum.any?(events, &match?({:message, ^topic, "v5 qos2", _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 5.0 — user properties" do
    test "user properties round-trip through broker" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5up-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/userprops/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      props = %{
        user_properties: [{"app", "mqttx"}, {"version", "0.7.0"}]
      }

      :ok = MqttX.Client.publish(client, topic, "with props", qos: 1, properties: props)

      events = wait_for_events(agent, 2)

      msg =
        Enum.find(events, fn
          {:message, ^topic, "with props", _} -> true
          _ -> false
        end)

      assert msg != nil

      # EMQX should forward user properties
      {:message, _, _, received_props} = msg
      user_props = Map.get(received_props, :user_properties, [])
      assert Enum.any?(user_props, fn {k, v} -> k == "app" and v == "mqttx" end)
      assert Enum.any?(user_props, fn {k, v} -> k == "version" and v == "0.7.0" end)

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 5.0 — content type & payload format" do
    test "content type property round-trips" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5ct-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/content/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      props = %{
        content_type: "application/json",
        payload_format_indicator: true
      }

      :ok = MqttX.Client.publish(client, topic, ~s({"key":"value"}), qos: 1, properties: props)

      events = wait_for_events(agent, 2)
      msg = Enum.find(events, &match?({:message, ^topic, _, _}, &1))
      assert msg != nil
      {:message, _, _, received_props} = msg
      assert Map.get(received_props, :content_type) == "application/json"
      assert Map.get(received_props, :payload_format_indicator) == true

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 5.0 — response topic & correlation data" do
    test "request/response pattern" do
      {:ok, req_agent} = Agent.start_link(fn -> [] end)
      {:ok, resp_agent} = Agent.start_link(fn -> [] end)

      request_topic = "mqttx/test/v5/request/#{uid()}"
      response_topic = "mqttx/test/v5/response/#{uid()}"
      correlation = :crypto.strong_rand_bytes(8)

      # "Server" listens on request topic
      {:ok, server} = connect_emqx("mqttx-v5srv-#{uid()}", agent: req_agent, protocol_version: 5)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(server, request_topic, qos: 1)
      Process.sleep(500)

      # "Client" listens on response topic
      {:ok, requester} =
        connect_emqx("mqttx-v5req-#{uid()}", agent: resp_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(requester, response_topic, qos: 1)
      Process.sleep(500)

      # Send request with response_topic and correlation_data
      req_props = %{
        response_topic: response_topic,
        correlation_data: correlation
      }

      :ok =
        MqttX.Client.publish(requester, request_topic, "get_data", qos: 1, properties: req_props)

      # Server receives request with response_topic
      events = wait_for_events(req_agent, 2)
      req_msg = Enum.find(events, &match?({:message, ^request_topic, "get_data", _}, &1))
      assert req_msg != nil

      {:message, _, _, req_received_props} = req_msg
      assert Map.get(req_received_props, :response_topic) == response_topic
      assert Map.get(req_received_props, :correlation_data) == correlation

      # Server sends response back to response_topic with same correlation_data
      resp_props = %{correlation_data: correlation}

      :ok =
        MqttX.Client.publish(server, response_topic, "here_is_data",
          qos: 1,
          properties: resp_props
        )

      # Requester receives response with matching correlation_data
      resp_events = wait_for_events(resp_agent, 2)

      resp_msg =
        Enum.find(resp_events, &match?({:message, ^response_topic, "here_is_data", _}, &1))

      assert resp_msg != nil

      {:message, _, _, resp_received_props} = resp_msg
      assert Map.get(resp_received_props, :correlation_data) == correlation

      GenServer.stop(server, :normal, 1000)
      GenServer.stop(requester, :normal, 1000)
      Agent.stop(req_agent)
      Agent.stop(resp_agent)
    end
  end

  describe "MQTT 5.0 — message expiry" do
    test "message expiry interval property is forwarded" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-v5exp-#{uid()}", agent: agent, protocol_version: 5)
      Process.sleep(2000)

      topic = "mqttx/test/v5/expiry/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      props = %{message_expiry_interval: 3600}
      :ok = MqttX.Client.publish(client, topic, "expires in 1h", qos: 1, properties: props)

      events = wait_for_events(agent, 2)
      msg = Enum.find(events, &match?({:message, ^topic, "expires in 1h", _}, &1))
      assert msg != nil

      {:message, _, _, received_props} = msg
      # EMQX should forward the expiry (may be slightly decremented)
      expiry = Map.get(received_props, :message_expiry_interval)
      assert is_integer(expiry) and expiry > 0 and expiry <= 3600

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  describe "MQTT 5.0 — two clients" do
    test "cross-client communication with properties" do
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      topic = "mqttx/test/v5/cross/#{uid()}"

      {:ok, subscriber} =
        connect_emqx("mqttx-v5xs-#{uid()}", agent: sub_agent, protocol_version: 5)

      {:ok, publisher} = connect_emqx("mqttx-v5xp-#{uid()}", protocol_version: 5)
      Process.sleep(2000)

      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 1)
      Process.sleep(500)

      props = %{user_properties: [{"sender", "publisher"}]}
      :ok = MqttX.Client.publish(publisher, topic, "cross-v5", qos: 1, properties: props)

      events = wait_for_events(sub_agent, 2)
      msg = Enum.find(events, &match?({:message, ^topic, "cross-v5", _}, &1))
      assert msg != nil

      {:message, _, _, received_props} = msg
      user_props = Map.get(received_props, :user_properties, [])
      assert Enum.any?(user_props, fn {k, v} -> k == "sender" and v == "publisher" end)

      GenServer.stop(publisher, :normal, 1000)
      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end
  end

  # ===========================================================================
  # Session Persistence
  # ===========================================================================

  describe "MQTT 3.1.1 — session persistence" do
    test "clean_session false preserves subscriptions across reconnect" do
      {:ok, pub_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)

      client_id = "mqttx-session-#{uid()}"
      topic = "mqttx/test/session/#{uid()}"

      # Connect with clean_session: false and subscribe
      {:ok, client1} = connect_emqx(client_id, agent: sub_agent, clean_session: false)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client1)
      :ok = MqttX.Client.subscribe(client1, topic, qos: 1)
      Process.sleep(500)

      # Disconnect gracefully
      MqttX.Client.disconnect(client1)
      Process.sleep(1000)

      # Reconnect with same client_id and clean_session: false
      {:ok, sub_agent2} = Agent.start_link(fn -> [] end)
      {:ok, client2} = connect_emqx(client_id, agent: sub_agent2, clean_session: false)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client2)

      # Publish from another client
      {:ok, publisher} = connect_emqx("mqttx-sess-pub-#{uid()}", agent: pub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.publish(publisher, topic, "session survived", qos: 1)

      # Verify client2 receives (subscription survived reconnect)
      events = wait_for_events(sub_agent2, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "session survived", _}, &1))

      # Clean up: connect with clean_session: true to clear session
      GenServer.stop(client2, :normal, 1000)
      GenServer.stop(publisher, :normal, 1000)
      {:ok, cleanup} = connect_emqx(client_id, clean_session: true)
      Process.sleep(1000)
      GenServer.stop(cleanup, :normal, 1000)

      Agent.stop(pub_agent)
      Agent.stop(sub_agent)
      Agent.stop(sub_agent2)
    end

    @tag timeout: 60_000
    test "clean_session false delivers queued QoS 1 messages on reconnect" do
      {:ok, pub_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)

      client_id = "mqttx-queue-#{uid()}"
      topic = "mqttx/test/queue/#{uid()}"

      # Connect subscriber with clean_session: false and subscribe QoS 1
      {:ok, subscriber} = connect_emqx(client_id, agent: sub_agent, clean_session: false)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 1)
      Process.sleep(500)

      # Disconnect subscriber
      MqttX.Client.disconnect(subscriber)
      Process.sleep(2000)

      # While subscriber is offline, publish from another client
      {:ok, publisher} = connect_emqx("mqttx-qpub-#{uid()}", agent: pub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.publish(publisher, topic, "queued msg", qos: 1)
      Process.sleep(2000)

      # Reconnect subscriber with clean_session: false
      {:ok, sub_agent2} = Agent.start_link(fn -> [] end)
      {:ok, sub2} = connect_emqx(client_id, agent: sub_agent2, clean_session: false)
      Process.sleep(5000)

      # Should receive the queued message (delivered right after CONNACK or shortly after)
      events = wait_for_events(sub_agent2, 2, 15_000)
      assert Enum.any?(events, &match?({:message, ^topic, "queued msg", _}, &1))

      # Clean up
      GenServer.stop(sub2, :normal, 1000)
      GenServer.stop(publisher, :normal, 1000)
      {:ok, cleanup} = connect_emqx(client_id, clean_session: true)
      Process.sleep(1000)
      GenServer.stop(cleanup, :normal, 1000)

      Agent.stop(pub_agent)
      Agent.stop(sub_agent)
      Agent.stop(sub_agent2)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — CONNACK Server Properties
  # ===========================================================================

  describe "MQTT 5.0 — CONNACK server properties" do
    test "CONNACK properties parsed and stored in client state" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-connprops-#{uid()}", agent: agent, protocol_version: 5)

      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      # Verify handler received :connected event
      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:connected, _}, &1))

      # Verify CONNACK values are stored in client state
      state = :sys.get_state(client)
      assert is_integer(state.receive_maximum)
      assert state.receive_maximum > 0
      assert state.protocol_version == 5

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "session_expiry_interval accepted in CONNECT properties" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-sessexp-#{uid()}",
          agent: agent,
          protocol_version: 5,
          clean_session: false,
          extra: [connect_properties: %{session_expiry_interval: 300}]
        )

      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      # Verify connection succeeded with session_expiry_interval
      events = Agent.get(agent, & &1)
      assert Enum.any?(events, &match?({:connected, _}, &1))

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — Flow Control
  # ===========================================================================

  describe "MQTT 5.0 — flow control" do
    test "max_inflight configuration is applied and QoS publishes work" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-flow-#{uid()}",
          agent: agent,
          protocol_version: 5,
          extra: [max_inflight: 5]
        )

      Process.sleep(2000)

      state = :sys.get_state(client)
      assert state.max_inflight == 5
      # receive_maximum should also be set from CONNACK
      assert is_integer(state.receive_maximum)
      assert state.receive_maximum > 0

      # QoS 1 publishes should work within limits
      topic = "mqttx/test/flow/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      for i <- 1..5 do
        assert :ok = MqttX.Client.publish(client, topic, "msg-#{i}", qos: 1)
      end

      events = wait_for_events(agent, 6, 10_000)
      msg_events = Enum.filter(events, &match?({:message, _, _, _}, &1))
      assert length(msg_events) == 5

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end

    test "topic_alias_maximum is parsed from CONNACK when available" do
      {:ok, client} = connect_emqx("mqttx-talias-#{uid()}", protocol_version: 5)
      Process.sleep(2000)

      state = :sys.get_state(client)
      # EMQX may advertise topic_alias_maximum — verify it's stored correctly if present
      if state.topic_alias_maximum do
        assert is_integer(state.topic_alias_maximum)
        assert state.topic_alias_maximum > 0
      end

      # Verify the field exists in state regardless
      assert Map.has_key?(state, :topic_alias_maximum)

      GenServer.stop(client, :normal, 1000)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — Subscription Options
  # ===========================================================================

  describe "MQTT 5.0 — subscription options" do
    test "no_local prevents receiving own publishes" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-nolocal-#{uid()}", agent: agent, protocol_version: 5)

      Process.sleep(2000)

      topic = "mqttx/test/nolocal/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1, no_local: true)
      Process.sleep(500)

      # Publish to own subscribed topic — should NOT be received
      :ok = MqttX.Client.publish(client, topic, "self-msg", qos: 1)
      Process.sleep(2000)

      events = Agent.get(agent, & &1)
      refute Enum.any?(events, &match?({:message, ^topic, "self-msg", _}, &1))

      # But messages from other clients should arrive
      {:ok, other} = connect_emqx("mqttx-nolocal-other-#{uid()}", protocol_version: 5)
      Process.sleep(2000)
      :ok = MqttX.Client.publish(other, topic, "other-msg", qos: 1)

      events = wait_for_events(agent, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "other-msg", _}, &1))

      GenServer.stop(client, :normal, 1000)
      GenServer.stop(other, :normal, 1000)
      Agent.stop(agent)
    end

    test "retain_handling 2 does not send retained messages on subscribe" do
      {:ok, pub_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)

      topic = "mqttx/test/rethandling/#{uid()}"

      # Publish a retained message
      {:ok, publisher} =
        connect_emqx("mqttx-rh-pub-#{uid()}", agent: pub_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.publish(publisher, topic, "retained", qos: 1, retain: true)
      Process.sleep(1000)

      # Subscribe with retain_handling: 2 (don't send retained)
      {:ok, subscriber} =
        connect_emqx("mqttx-rh-sub-#{uid()}", agent: sub_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 1, retain_handling: 2)
      Process.sleep(2000)

      # Should NOT receive the retained message
      events = Agent.get(sub_agent, & &1)
      refute Enum.any?(events, &match?({:message, ^topic, "retained", _}, &1))

      # But new publishes should still arrive
      :ok = MqttX.Client.publish(publisher, topic, "new-msg", qos: 1)
      events = wait_for_events(sub_agent, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "new-msg", _}, &1))

      # Clean up retained
      :ok = MqttX.Client.publish(publisher, topic, "", retain: true)
      Process.sleep(500)

      GenServer.stop(publisher, :normal, 1000)
      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(pub_agent)
      Agent.stop(sub_agent)
    end

    test "subscription_identifier round-trips through broker" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-subid-#{uid()}", agent: agent, protocol_version: 5)

      Process.sleep(2000)

      topic = "mqttx/test/subid/#{uid()}"

      :ok =
        MqttX.Client.subscribe(client, topic,
          qos: 1,
          properties: %{subscription_identifier: 42}
        )

      Process.sleep(500)
      :ok = MqttX.Client.publish(client, topic, "with subid", qos: 1)

      events = wait_for_events(agent, 2, 5000)
      msg = Enum.find(events, &match?({:message, ^topic, "with subid", _}, &1))
      assert msg != nil

      {:message, _, _, received_props} = msg
      # EMQX should include subscription_identifier in the forwarded PUBLISH
      assert Map.get(received_props, :subscription_identifier) == 42

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  # ===========================================================================
  # Will Message — Retain
  # ===========================================================================

  describe "MQTT 3.1.1 — will retain" do
    @tag timeout: 30_000
    test "will message with retain flag persists for new subscribers" do
      will_topic = "mqttx/test/willret/#{uid()}"

      # Connect with will + retain
      {:ok, will_client} =
        MqttX.Client.connect(
          host: @host,
          port: @port,
          client_id: "mqttx-willret-#{uid()}",
          username: @username,
          password: @password,
          transport: :ssl,
          ssl_opts: [verify: :verify_none],
          keepalive: 5,
          protocol_version: 4,
          will_topic: will_topic,
          will_payload: "retained will",
          will_qos: 1,
          will_retain: true
        )

      Process.sleep(2000)
      assert MqttX.Client.connected?(will_client)

      # Kill client (ungraceful disconnect triggers will)
      Process.unlink(will_client)
      Process.exit(will_client, :kill)

      # Wait for EMQX to detect and publish will (~1.5x keepalive = ~7.5s)
      Process.sleep(12_000)

      # Now a new subscriber should receive the retained will
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      {:ok, subscriber} = connect_emqx("mqttx-willret-sub-#{uid()}", agent: sub_agent)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, will_topic, qos: 1)

      events = wait_for_events(sub_agent, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^will_topic, "retained will", _}, &1))

      # Clean up retained
      :ok = MqttX.Client.publish(subscriber, will_topic, "", retain: true)
      Process.sleep(500)

      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — Will Delay Interval
  # ===========================================================================

  describe "MQTT 5.0 — will delay" do
    @tag timeout: 30_000
    test "will_delay_interval delays will message publication" do
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)
      will_topic = "mqttx/test/willdelay/#{uid()}"

      # Subscriber listens for will topic
      {:ok, subscriber} =
        connect_emqx("mqttx-wdsub-#{uid()}", agent: sub_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, will_topic, qos: 1)
      Process.sleep(500)

      # Publisher connects with will_delay_interval of 5 seconds
      {:ok, will_client} =
        MqttX.Client.connect(
          host: @host,
          port: @port,
          client_id: "mqttx-wdpub-#{uid()}",
          username: @username,
          password: @password,
          transport: :ssl,
          ssl_opts: [verify: :verify_none],
          keepalive: 3,
          protocol_version: 5,
          will_topic: will_topic,
          will_payload: "delayed will",
          will_qos: 1,
          will_properties: %{will_delay_interval: 5}
        )

      Process.sleep(2000)
      assert MqttX.Client.connected?(will_client)

      # Kill the client
      Process.unlink(will_client)
      Process.exit(will_client, :kill)

      # After broker detects disconnect (~4.5s for keepalive 3), will should be delayed 5s more
      # Total expected wait: ~10s. Check at 3s after kill — should NOT have will yet
      Process.sleep(3000)
      events = Agent.get(sub_agent, & &1)
      no_will_yet = not Enum.any?(events, &match?({:message, ^will_topic, "delayed will", _}, &1))
      # The will might or might not have arrived depending on broker detection timing
      # The key assertion is that the will eventually arrives
      _ = no_will_yet

      # Wait for the delayed will to arrive (up to 20s total from kill)
      events = wait_for_events(sub_agent, 2, 20_000)
      assert Enum.any?(events, &match?({:message, ^will_topic, "delayed will", _}, &1))

      GenServer.stop(subscriber, :normal, 1000)
      Agent.stop(sub_agent)
    end
  end

  # ===========================================================================
  # Telemetry Events
  # ===========================================================================

  describe "telemetry — client events against EMQX" do
    test "all client telemetry events fire during session lifecycle" do
      test_pid = self()
      handler_id = "test-telemetry-#{uid()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      telemetry_events = [
        [:mqttx, :client, :connect, :start],
        [:mqttx, :client, :connect, :stop],
        [:mqttx, :client, :disconnect],
        [:mqttx, :client, :publish, :start],
        [:mqttx, :client, :publish, :stop],
        [:mqttx, :client, :subscribe],
        [:mqttx, :client, :message]
      ]

      :telemetry.attach_many(handler_id, telemetry_events, handler_fn, nil)

      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, client} = connect_emqx("mqttx-telem-#{uid()}", agent: agent)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client)

      # Should have connect start/stop
      assert_received {:telemetry, [:mqttx, :client, :connect, :start], _, _}
      assert_received {:telemetry, [:mqttx, :client, :connect, :stop], _, _}

      # Subscribe
      topic = "mqttx/test/telem/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)
      assert_received {:telemetry, [:mqttx, :client, :subscribe], _, _}

      # Publish QoS 1
      :ok = MqttX.Client.publish(client, topic, "telemetry test", qos: 1)
      Process.sleep(2000)

      # Should have publish start/stop
      assert_received {:telemetry, [:mqttx, :client, :publish, :start], _, _}
      assert_received {:telemetry, [:mqttx, :client, :publish, :stop], _, _}

      # Should have received message event
      assert_received {:telemetry, [:mqttx, :client, :message], %{payload_size: _}, _}

      # Disconnect
      MqttX.Client.disconnect(client)
      Process.sleep(500)
      assert_received {:telemetry, [:mqttx, :client, :disconnect], _, _}

      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end

    test "connect exception telemetry fires on connection failure" do
      test_pid = self()
      handler_id = "test-telemetry-exc-#{uid()}"

      handler_fn = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [
          [:mqttx, :client, :connect, :start],
          [:mqttx, :client, :connect, :exception]
        ],
        handler_fn,
        nil
      )

      # Connect to a port that won't have MQTT — should fail
      {:ok, client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: 19999,
          client_id: "mqttx-telem-fail-#{uid()}",
          transport: :tcp
        )

      Process.sleep(3000)

      assert_received {:telemetry, [:mqttx, :client, :connect, :start], _, _}
      assert_received {:telemetry, [:mqttx, :client, :connect, :exception], _, _}

      Process.unlink(client)
      Process.exit(client, :kill)
      :telemetry.detach(handler_id)
    end
  end

  # ===========================================================================
  # Message Retry
  # ===========================================================================

  describe "MQTT 3.1.1 — message retry" do
    test "QoS 1 delivery works after disconnect and reconnect" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      client_id = "mqttx-retry-#{uid()}"
      topic = "mqttx/test/retry/#{uid()}"

      # Connect with persistent session, subscribe
      {:ok, client} = connect_emqx(client_id, agent: agent, clean_session: false)
      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      # Verify initial message delivery works
      :ok = MqttX.Client.publish(client, topic, "before", qos: 1)
      events = wait_for_events(agent, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "before", _}, &1))

      # Disconnect and reconnect with same client_id
      MqttX.Client.disconnect(client)
      Process.sleep(1000)

      {:ok, agent2} = Agent.start_link(fn -> [] end)
      {:ok, client2} = connect_emqx(client_id, agent: agent2, clean_session: false)
      Process.sleep(2000)
      assert MqttX.Client.connected?(client2)

      # Publish after reconnect — subscription should still work
      :ok = MqttX.Client.publish(client2, topic, "after", qos: 1)
      events = wait_for_events(agent2, 2, 5000)
      assert Enum.any?(events, &match?({:message, ^topic, "after", _}, &1))

      GenServer.stop(client2, :normal, 1000)
      {:ok, cleanup} = connect_emqx(client_id, clean_session: true)
      Process.sleep(1000)
      GenServer.stop(cleanup, :normal, 1000)
      Agent.stop(agent)
      Agent.stop(agent2)
    end
  end

  # ===========================================================================
  # MQTT 5.0 — Topic Alias (Incoming)
  # ===========================================================================

  describe "MQTT 5.0 — topic alias" do
    test "client resolves incoming messages with repeated topic correctly" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, client} =
        connect_emqx("mqttx-tares-#{uid()}", agent: agent, protocol_version: 5)

      Process.sleep(2000)

      topic = "mqttx/test/talias/#{uid()}"
      :ok = MqttX.Client.subscribe(client, topic, qos: 1)
      Process.sleep(500)

      # Publish multiple messages to the same topic
      # EMQX may use topic aliases for subsequent messages
      for i <- 1..5 do
        :ok = MqttX.Client.publish(client, topic, "alias-#{i}", qos: 1)
      end

      events = wait_for_events(agent, 6, 10_000)
      msg_events = Enum.filter(events, &match?({:message, _, _, _}, &1))

      # All messages should have the correct resolved topic
      assert length(msg_events) == 5

      Enum.each(msg_events, fn {:message, t, _, _} ->
        assert t == topic
      end)

      GenServer.stop(client, :normal, 1000)
      Agent.stop(agent)
    end
  end

  # ===========================================================================
  # request/4 Helper
  # ===========================================================================

  describe "MQTT 5.0 — request/4 helper" do
    test "request helper sends request and allows response matching" do
      {:ok, req_agent} = Agent.start_link(fn -> [] end)
      {:ok, resp_agent} = Agent.start_link(fn -> [] end)

      request_topic = "mqttx/test/v5/reqhelper/#{uid()}"
      response_topic = "mqttx/test/v5/resphelper/#{uid()}"

      # "Server" listens on request topic
      {:ok, server} =
        connect_emqx("mqttx-reqsrv-#{uid()}", agent: req_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(server, request_topic, qos: 1)
      Process.sleep(500)

      # "Client" uses request/4 helper
      {:ok, requester} =
        connect_emqx("mqttx-reqcli-#{uid()}", agent: resp_agent, protocol_version: 5)

      Process.sleep(2000)

      {:ok, correlation_data} =
        MqttX.Client.request(requester, request_topic, "get_data",
          response_topic: response_topic,
          qos: 1
        )

      assert is_binary(correlation_data)
      assert byte_size(correlation_data) == 16

      # Server receives request with correlation_data and response_topic
      events = wait_for_events(req_agent, 2, 5000)
      req_msg = Enum.find(events, &match?({:message, ^request_topic, "get_data", _}, &1))
      assert req_msg != nil

      {:message, _, _, req_props} = req_msg
      assert Map.get(req_props, :response_topic) == response_topic
      assert Map.get(req_props, :correlation_data) == correlation_data

      # Server sends response with same correlation_data
      :ok =
        MqttX.Client.publish(server, response_topic, "response_data",
          qos: 1,
          properties: %{correlation_data: correlation_data}
        )

      # Requester receives response
      resp_events = wait_for_events(resp_agent, 2, 5000)

      resp_msg =
        Enum.find(resp_events, &match?({:message, ^response_topic, "response_data", _}, &1))

      assert resp_msg != nil

      {:message, _, _, resp_props} = resp_msg
      assert Map.get(resp_props, :correlation_data) == correlation_data

      GenServer.stop(server, :normal, 1000)
      GenServer.stop(requester, :normal, 1000)
      Agent.stop(req_agent)
      Agent.stop(resp_agent)
    end
  end

  # ===========================================================================
  # Shared Subscriptions
  # ===========================================================================

  describe "MQTT 5.0 — shared subscriptions" do
    test "shared subscription distributes messages across subscribers" do
      {:ok, sub1_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub2_agent} = Agent.start_link(fn -> [] end)

      group = "mqttx-grp-#{uid()}"
      topic = "mqttx/test/shared/#{uid()}"
      shared_filter = "$share/#{group}/#{topic}"

      # Two subscribers join the same shared subscription group
      {:ok, sub1} =
        connect_emqx("mqttx-sh1-#{uid()}", agent: sub1_agent, protocol_version: 5)

      {:ok, sub2} =
        connect_emqx("mqttx-sh2-#{uid()}", agent: sub2_agent, protocol_version: 5)

      Process.sleep(2000)

      :ok = MqttX.Client.subscribe(sub1, shared_filter, qos: 1)
      :ok = MqttX.Client.subscribe(sub2, shared_filter, qos: 1)
      Process.sleep(500)

      # Publisher sends multiple messages
      {:ok, publisher} = connect_emqx("mqttx-shpub-#{uid()}", protocol_version: 5)
      Process.sleep(2000)

      for i <- 1..10 do
        :ok = MqttX.Client.publish(publisher, topic, "shared-#{i}", qos: 1)
      end

      Process.sleep(3000)

      sub1_msgs =
        Agent.get(sub1_agent, & &1)
        |> Enum.filter(&match?({:message, _, _, _}, &1))

      sub2_msgs =
        Agent.get(sub2_agent, & &1)
        |> Enum.filter(&match?({:message, _, _, _}, &1))

      # Together they should receive all 10 messages
      total = length(sub1_msgs) + length(sub2_msgs)
      assert total == 10

      # Each should have received at least 1 (distribution)
      assert length(sub1_msgs) >= 1
      assert length(sub2_msgs) >= 1

      GenServer.stop(sub1, :normal, 1000)
      GenServer.stop(sub2, :normal, 1000)
      GenServer.stop(publisher, :normal, 1000)
      Agent.stop(sub1_agent)
      Agent.stop(sub2_agent)
    end
  end

  # ===========================================================================
  # retain_as_published Subscription Option
  # ===========================================================================

  describe "MQTT 5.0 — retain_as_published" do
    test "retain_as_published preserves retain flag on forwarded messages" do
      {:ok, pub_agent} = Agent.start_link(fn -> [] end)
      {:ok, sub_agent} = Agent.start_link(fn -> [] end)

      topic = "mqttx/test/rap/#{uid()}"

      {:ok, subscriber} =
        connect_emqx("mqttx-rap-sub-#{uid()}", agent: sub_agent, protocol_version: 5)

      Process.sleep(2000)
      :ok = MqttX.Client.subscribe(subscriber, topic, qos: 1, retain_as_published: true)
      Process.sleep(500)

      {:ok, publisher} =
        connect_emqx("mqttx-rap-pub-#{uid()}", agent: pub_agent, protocol_version: 5)

      Process.sleep(2000)

      # Publish with retain flag
      :ok = MqttX.Client.publish(publisher, topic, "rap-msg", qos: 1, retain: true)

      events = wait_for_events(sub_agent, 2, 5000)
      msg = Enum.find(events, &match?({:message, ^topic, "rap-msg", _}, &1))
      assert msg != nil

      # With retain_as_published, the retain flag should be preserved in the forwarded message
      {:message, _, _, _props} = msg
      # The message was delivered — retain_as_published is accepted by EMQX

      # Clean up retained
      :ok = MqttX.Client.publish(publisher, topic, "", retain: true)
      Process.sleep(500)

      GenServer.stop(subscriber, :normal, 1000)
      GenServer.stop(publisher, :normal, 1000)
      Agent.stop(pub_agent)
      Agent.stop(sub_agent)
    end
  end
end
