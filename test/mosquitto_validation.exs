## Comprehensive Mosquitto Client Validation Script
## Run with: mix run test/mosquitto_validation.exs
##
## Tests every MQTT feature exercisable via mosquitto_pub/mosquitto_sub
## against both TCP (ThousandIsland) and WebSocket (Bandit) transports.

defmodule PubSubHandler do
  @moduledoc "Broker handler that forwards publishes to topic-matched subscribers"
  use MqttX.Server

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :sub_table)
    event_table = Keyword.fetch!(opts, :event_table)
    %{sub_table: table, event_table: event_table}
  end

  @impl true
  def handle_connect(client_id, credentials, state) do
    record_event(state, {:connect, client_id, credentials})
    {:ok, Map.put(state, :client_id, client_id)}
  end

  @impl true
  def handle_publish(topic, payload, opts, state) do
    topic_str = flatten_topic(topic)
    record_event(state, {:publish, topic_str, payload, opts})

    # Forward to matching subscribers
    :ets.foldl(
      fn {pid, sub_topic}, _acc ->
        if topic_matches?(topic_str, sub_topic) do
          send(pid, {:forward_publish, topic_str, payload, opts})
        end

        :ok
      end,
      :ok,
      state.sub_table
    )

    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state) do
    pid = self()

    for t <- topics do
      topic_str = flatten_topic(t.topic)
      :ets.insert(state.sub_table, {pid, topic_str})
    end

    record_event(state, {:subscribe, Enum.map(topics, &flatten_topic(&1.topic))})
    qos_list = Enum.map(topics, fn t -> Map.get(t, :qos, 0) end)
    {:ok, qos_list, state}
  end

  @impl true
  def handle_unsubscribe(topics, state) do
    pid = self()

    normalized =
      Enum.map(topics, fn
        t when is_list(t) -> flatten_topic(t)
        t when is_binary(t) -> t
      end)

    for topic_str <- normalized do
      :ets.match_delete(state.sub_table, {pid, topic_str})
    end

    record_event(state, {:unsubscribe, normalized})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    record_event(state, {:disconnect, reason, Map.get(state, :client_id)})
    :ok
  end

  @impl true
  def handle_puback(packet_id, state) do
    record_event(state, {:puback, packet_id})
    {:ok, state}
  end

  @impl true
  def handle_info({:forward_publish, topic, payload, _opts}, state) do
    {:publish, topic, payload, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  defp flatten_topic(topic) when is_binary(topic), do: topic

  defp flatten_topic(parts) when is_list(parts) do
    Enum.map_join(parts, "/", fn
      :single_level -> "+"
      :multi_level -> "#"
      other -> to_string(other)
    end)
  end

  defp topic_matches?(topic, filter) do
    topic_parts = String.split(topic, "/")
    filter_parts = String.split(filter, "/")
    do_match?(topic_parts, filter_parts)
  end

  defp do_match?(_, ["#"]), do: true
  defp do_match?([], []), do: true
  defp do_match?([], _), do: false
  defp do_match?(_, []), do: false
  defp do_match?([_ | t1], ["+" | t2]), do: do_match?(t1, t2)
  defp do_match?([h | t1], [h | t2]), do: do_match?(t1, t2)
  defp do_match?(_, _), do: false

  defp record_event(state, event) do
    :ets.insert(state.event_table, {System.monotonic_time(), event})
  end
end

defmodule AuthHandler do
  @moduledoc "Handler that requires username/password authentication"
  use MqttX.Server

  @impl true
  def init(opts),
    do: %{
      sub_table: Keyword.fetch!(opts, :sub_table),
      event_table: Keyword.fetch!(opts, :event_table)
    }

  @impl true
  def handle_connect(_client_id, %{username: "valid_user", password: "valid_pass"}, state) do
    {:ok, state}
  end

  def handle_connect(_client_id, _credentials, state) do
    {:error, 0x86, state}
  end

  @impl true
  def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

  @impl true
  def handle_subscribe(topics, state) do
    {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
  end

  @impl true
  def handle_disconnect(_reason, _state), do: :ok
end

defmodule Validation do
  @moduledoc false

  def run do
    IO.puts("\n================================================================")
    IO.puts("  MqttX Broker — Comprehensive Mosquitto Client Validation")
    IO.puts("================================================================\n")

    # Shared state
    sub_table = :ets.new(:validation_subs, [:public, :duplicate_bag])
    event_table = :ets.new(:validation_events, [:public, :ordered_set])

    tcp_port = get_free_port()
    ws_port = get_free_port()
    auth_port = get_free_port()

    IO.puts("Starting servers...")

    {:ok, tcp_pid} =
      MqttX.Server.start_link(PubSubHandler, [sub_table: sub_table, event_table: event_table],
        transport: MqttX.Transport.ThousandIsland,
        port: tcp_port
      )

    {:ok, ws_pid} =
      MqttX.Server.start_link(PubSubHandler, [sub_table: sub_table, event_table: event_table],
        transport: MqttX.Transport.WebSocket,
        port: ws_port
      )

    {:ok, auth_pid} =
      MqttX.Server.start_link(AuthHandler, [sub_table: sub_table, event_table: event_table],
        transport: MqttX.Transport.ThousandIsland,
        port: auth_port
      )

    Process.sleep(300)
    IO.puts("  TCP on #{tcp_port}, WS on #{ws_port}, Auth on #{auth_port}\n")

    all_results =
      run_transport_suite("TCP", tcp_port, []) ++
        run_transport_suite("WS", ws_port, ["--ws"]) ++
        run_auth_suite(auth_port) ++
        run_cross_transport_suite(tcp_port, ws_port) ++
        run_protocol_version_suite(tcp_port)

    print_summary(all_results)

    GenServer.stop(tcp_pid, :normal, 1000)
    GenServer.stop(ws_pid, :normal, 1000)
    GenServer.stop(auth_pid, :normal, 1000)

    if Enum.any?(all_results, fn {_, s} -> s == :fail end) do
      System.halt(1)
    end
  end

  # -----------------------------------------------------------------------
  # Transport-specific suite (runs once for TCP, once for WS)
  # -----------------------------------------------------------------------
  defp run_transport_suite(label, port, ws_flags) do
    IO.puts("--- #{label}: Basic Connectivity ---\n")

    base_pub = ws_flags ++ ["-h", "127.0.0.1", "-p", "#{port}"]
    base_sub = ws_flags ++ ["-h", "127.0.0.1", "-p", "#{port}"]

    r1 = [
      # -- Basic Connectivity --
      test("#{label}: connect and publish QoS 0", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/basic/q0", "-m", "q0-msg", "-q", "0"]
        )
      end),
      test("#{label}: connect and publish QoS 1", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/basic/q1", "-m", "q1-msg", "-q", "1"]
        )
      end),
      test("#{label}: connect and publish QoS 2", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/basic/q2", "-m", "q2-msg", "-q", "2"]
        )
      end),
      test("#{label}: publish with explicit client ID", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-i", "#{label}-explicit-id", "-t", "#{label}/clientid", "-m", "id-test"]
        )
      end),
      test("#{label}: publish empty payload (-n)", fn ->
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/empty", "-n"])
      end),
      test("#{label}: publish large payload (64KB)", fn ->
        payload = String.duplicate("X", 65536)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/large64k", "-m", payload])
      end),
      test("#{label}: publish large payload (256KB)", fn ->
        payload = String.duplicate("Y", 262_144)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/large256k", "-m", payload])
      end),
      test("#{label}: publish with keepalive", fn ->
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/ka", "-m", "keepalive", "-k", "5"])
      end)
    ]

    IO.puts("\n--- #{label}: Pub/Sub Round-Trips ---\n")

    r2 = [
      test("#{label}: pub/sub QoS 0", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/ps/q0", "q0-data", 0, 0)
      end),
      test("#{label}: pub/sub QoS 1", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/ps/q1", "q1-data", 1, 1)
      end),
      test("#{label}: pub/sub QoS 2", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/ps/q2", "q2-data", 2, 2)
      end),
      test("#{label}: pub QoS 1 / sub QoS 0 (downgrade)", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/ps/q1q0", "downgrade", 0, 1)
      end),
      test("#{label}: multiple messages (5 sequential)", fn ->
        multi_message_test(base_sub, base_pub, "#{label}/ps/multi5", 5)
      end),
      test("#{label}: multiple messages (20 rapid)", fn ->
        multi_message_test(base_sub, base_pub, "#{label}/ps/multi20", 20)
      end),
      test("#{label}: pub/sub large payload round-trip (64KB)", fn ->
        payload = String.duplicate("Z", 65536)

        pubsub_roundtrip_raw(
          base_sub,
          base_pub,
          "#{label}/ps/large64k",
          payload,
          0,
          0,
          fn output ->
            String.length(String.trim(output)) == 65536
          end
        )
      end)
    ]

    IO.puts("\n--- #{label}: Wildcard Subscriptions ---\n")

    r3 = [
      test("#{label}: multi-level wildcard (#)", fn ->
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/wild/ml/#", "-C", "2", "-W", "5"])
        Process.sleep(500)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/ml/a", "-m", "ml-a"])
        Process.sleep(100)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/ml/b/c", "-m", "ml-bc"])
        expect_lines(sub_task, 2)
      end),
      test("#{label}: single-level wildcard (+)", fn ->
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/wild/sl/+/data", "-C", "2", "-W", "5"])
        Process.sleep(500)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/sl/sensor1/data", "-m", "s1"])
        Process.sleep(100)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/sl/sensor2/data", "-m", "s2"])
        expect_lines(sub_task, 2)
      end),
      test("#{label}: wildcard + does not match multi-level", fn ->
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/wild/nomatch/+", "-C", "1", "-W", "2"])
        Process.sleep(500)
        # This should NOT be received (too deep)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/nomatch/a/b", "-m", "nope"])
        {output, exit_code} = Task.await(sub_task, 10_000)
        # Should time out with no messages
        if exit_code == 27 or (exit_code != 0 and String.contains?(output, "Timed out")) do
          :ok
        else
          if String.trim(output) == "" do
            :ok
          else
            {:error, "Expected no messages, got: #{inspect(String.trim(output))}"}
          end
        end
      end),
      test("#{label}: root wildcard (#) receives everything", fn ->
        sub_task = async_sub(base_sub ++ ["-t", "#", "-C", "2", "-W", "5"])
        Process.sleep(500)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/root/x", "-m", "root1"])
        Process.sleep(100)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/wild/root/y/z", "-m", "root2"])
        expect_lines(sub_task, 2)
      end),
      test("#{label}: multiple subscriptions on same connection", fn ->
        sub_task =
          async_sub(
            base_sub ++
              ["-t", "#{label}/multi/topicA", "-t", "#{label}/multi/topicB", "-C", "2", "-W", "5"]
          )

        Process.sleep(500)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/multi/topicA", "-m", "fromA"])
        Process.sleep(100)
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/multi/topicB", "-m", "fromB"])
        expect_lines(sub_task, 2)
      end)
    ]

    IO.puts("\n--- #{label}: Retained Messages ---\n")

    r4 = [
      test("#{label}: retained message delivered on subscribe", fn ->
        # Publish with retain flag
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/test1", "-m", "retained-payload", "-r"]
        )

        Process.sleep(200)
        # Subscribe — should immediately get the retained message
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/retained/test1", "-C", "1", "-W", "3"])
        expect_exact(sub_task, "retained-payload")
      end),
      test("#{label}: retained message overwrite", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/overwrite", "-m", "old-value", "-r"]
        )

        Process.sleep(100)

        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/overwrite", "-m", "new-value", "-r"]
        )

        Process.sleep(200)

        sub_task =
          async_sub(base_sub ++ ["-t", "#{label}/retained/overwrite", "-C", "1", "-W", "3"])

        expect_exact(sub_task, "new-value")
      end),
      test("#{label}: retained message deleted by empty publish", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/delete", "-m", "to-delete", "-r"]
        )

        Process.sleep(100)
        # Delete by publishing empty retained
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/retained/delete", "-n", "-r"])
        Process.sleep(200)
        # Subscribe — should NOT get a retained message, expect timeout
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/retained/delete", "-C", "1", "-W", "2"])
        expect_timeout(sub_task)
      end),
      test("#{label}: retained message with wildcard subscribe", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/wild/a", "-m", "rw-a", "-r"]
        )

        Process.sleep(100)

        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/retained/wild/b", "-m", "rw-b", "-r"]
        )

        Process.sleep(200)
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/retained/wild/#", "-C", "2", "-W", "3"])
        expect_lines(sub_task, 2)
      end)
    ]

    IO.puts("\n--- #{label}: Will Messages ---\n")

    r5 = [
      test("#{label}: will message on ungraceful disconnect", fn ->
        # Start subscriber for the will topic
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/will/fired", "-C", "1", "-W", "5"])
        Process.sleep(500)
        # Use raw TCP/WS to connect with a will, then abruptly close the socket
        # Port.close on mosquitto sends SIGTERM which triggers graceful DISCONNECT,
        # so we must use raw sockets to simulate a truly ungraceful disconnect.
        raw_connect_with_will_then_crash(port, ws_flags,
          will_topic: "#{label}/will/fired",
          will_payload: "client-died",
          will_qos: 0,
          client_id: "#{label}-will-crash"
        )

        # Wait for will to be published and delivered
        Process.sleep(500)
        expect_exact(sub_task, "client-died")
      end),
      test("#{label}: will message NOT sent on graceful disconnect", fn ->
        # mosquitto_pub with --will-topic sends graceful DISCONNECT, so will should NOT fire
        run_cmd(
          "mosquitto_pub",
          base_pub ++
            [
              "-t",
              "#{label}/will/grace/trigger",
              "-m",
              "trigger",
              "--will-topic",
              "#{label}/will/grace/should_not_fire",
              "--will-payload",
              "ghost",
              "--will-qos",
              "0"
            ]
        )

        Process.sleep(300)

        sub_task =
          async_sub(
            base_sub ++ ["-t", "#{label}/will/grace/should_not_fire", "-C", "1", "-W", "2"]
          )

        expect_timeout(sub_task)
      end),
      test("#{label}: will message with QoS 1", fn ->
        sub_task =
          async_sub(base_sub ++ ["-t", "#{label}/will/q1", "-q", "1", "-C", "1", "-W", "5"])

        Process.sleep(500)

        raw_connect_with_will_then_crash(port, ws_flags,
          will_topic: "#{label}/will/q1",
          will_payload: "will-q1-data",
          will_qos: 1,
          client_id: "#{label}-will-q1-crash"
        )

        Process.sleep(500)
        expect_exact(sub_task, "will-q1-data")
      end)
    ]

    IO.puts("\n--- #{label}: Unsubscribe ---\n")

    r6 = [
      test("#{label}: unsubscribe stops message delivery", fn ->
        # Use -U flag in mosquitto_sub to unsubscribe
        # Strategy: subscribe to two topics, unsubscribe from one, publish to both
        # mosquitto_sub -t A -t B -U A -C 1 (should only get B)
        sub_task =
          async_sub(
            base_sub ++
              [
                "-t",
                "#{label}/unsub/keep",
                "-t",
                "#{label}/unsub/remove",
                "-U",
                "#{label}/unsub/remove",
                "-C",
                "1",
                "-W",
                "5"
              ]
          )

        Process.sleep(500)
        # Publish to the removed topic first
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/unsub/remove", "-m", "should-not-get"]
        )

        Process.sleep(200)
        # Publish to the kept topic
        run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/unsub/keep", "-m", "should-get"])
        expect_exact(sub_task, "should-get")
      end)
    ]

    IO.puts("\n--- #{label}: Topic Edge Cases ---\n")

    r7 = [
      test("#{label}: deep topic hierarchy (10 levels)", fn ->
        topic = "#{label}/deep/l1/l2/l3/l4/l5/l6/l7/l8"
        pubsub_roundtrip(base_sub, base_pub, topic, "deep-msg", 0, 0)
      end),
      test("#{label}: topic with spaces", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/spaces/hello world", "space-msg", 0, 0)
      end),
      test("#{label}: topic with UTF-8 characters", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/utf8/日本語/données", "utf8-msg", 0, 0)
      end),
      test("#{label}: topic with emoji", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/emoji/🌡️/sensor", "emoji-msg", 0, 0)
      end),
      test("#{label}: single character topic", fn ->
        pubsub_roundtrip(base_sub, base_pub, "x", "single-char", 0, 0)
      end),
      test("#{label}: topic with numbers", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/123/456/789", "num-msg", 0, 0)
      end),
      test("#{label}: topic with dashes and underscores", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/my-topic/sub_topic", "dash-msg", 0, 0)
      end)
    ]

    IO.puts("\n--- #{label}: Payload Edge Cases ---\n")

    r8 = [
      test("#{label}: binary-like payload (null bytes in string)", fn ->
        # mosquitto_pub -m sends as string, but let's test special chars
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/payload/special", "-m", "line1\nline2\ttab"]
        )
      end),
      test("#{label}: max-length client ID (23 chars MQTT 3.1.1)", fn ->
        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-i", "12345678901234567890123", "-t", "#{label}/longid", "-m", "ok"]
        )
      end),
      test("#{label}: very long client ID (128 chars)", fn ->
        long_id = String.duplicate("a", 128)

        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-i", long_id, "-t", "#{label}/verylongid", "-m", "ok"]
        )
      end),
      test("#{label}: JSON payload", fn ->
        json = ~s({"temperature":23.5,"unit":"celsius","timestamp":1709568000})
        pubsub_roundtrip(base_sub, base_pub, "#{label}/payload/json", json, 0, 0)
      end),
      test("#{label}: payload with unicode", fn ->
        pubsub_roundtrip(base_sub, base_pub, "#{label}/payload/unicode", "こんにちは世界 🌍", 0, 0)
      end)
    ]

    IO.puts("\n--- #{label}: Connection Behavior ---\n")

    r9 = [
      test("#{label}: rapid connect/disconnect (10x)", fn ->
        results =
          for i <- 1..10 do
            run_cmd("mosquitto_pub", base_pub ++ ["-t", "#{label}/rapid/#{i}", "-m", "r#{i}"])
          end

        if Enum.all?(results, &(&1 == :ok)),
          do: :ok,
          else: {:error, "Some rapid connections failed"}
      end),
      test("#{label}: concurrent publishers (5 simultaneous)", fn ->
        tasks =
          for i <- 1..5 do
            Task.async(fn ->
              run_cmd(
                "mosquitto_pub",
                base_pub ++ ["-t", "#{label}/concurrent/#{i}", "-m", "c#{i}"]
              )
            end)
          end

        results = Enum.map(tasks, &Task.await(&1, 10_000))

        if Enum.all?(results, &(&1 == :ok)),
          do: :ok,
          else: {:error, "Some concurrent publishes failed"}
      end),
      test("#{label}: concurrent subscribers receive same message", fn ->
        # Start 3 subscribers
        sub_tasks =
          for _i <- 1..3 do
            async_sub(base_sub ++ ["-t", "#{label}/concurrent/fanout", "-C", "1", "-W", "5"])
          end

        Process.sleep(500)

        run_cmd(
          "mosquitto_pub",
          base_pub ++ ["-t", "#{label}/concurrent/fanout", "-m", "broadcast"]
        )

        results =
          Enum.map(sub_tasks, fn task ->
            {output, exit_code} = Task.await(task, 10_000)
            exit_code == 0 and String.trim(output) == "broadcast"
          end)

        if Enum.all?(results), do: :ok, else: {:error, "Not all subscribers received the message"}
      end),
      test("#{label}: publish with repeat (3x)", fn ->
        sub_task = async_sub(base_sub ++ ["-t", "#{label}/repeat", "-C", "3", "-W", "5"])
        Process.sleep(500)

        run_cmd(
          "mosquitto_pub",
          base_pub ++
            ["-t", "#{label}/repeat", "-m", "rep", "--repeat", "3", "--repeat-delay", "0"]
        )

        expect_lines(sub_task, 3)
      end)
    ]

    IO.puts("")

    r1 ++ r2 ++ r3 ++ r4 ++ r5 ++ r6 ++ r7 ++ r8 ++ r9
  end

  # -----------------------------------------------------------------------
  # Authentication suite
  # -----------------------------------------------------------------------
  defp run_auth_suite(port) do
    IO.puts("--- AUTH: Username/Password Authentication ---\n")

    base = ["-h", "127.0.0.1", "-p", "#{port}"]

    results = [
      test("AUTH: valid credentials accepted", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++ ["-u", "valid_user", "-P", "valid_pass", "-t", "auth/ok", "-m", "authenticated"]
        )
      end),
      test("AUTH: invalid password rejected", fn ->
        result =
          run_cmd(
            "mosquitto_pub",
            base ++
              ["-u", "valid_user", "-P", "wrong_pass", "-t", "auth/fail1", "-m", "should-fail"]
          )

        case result do
          {:error, _} -> :ok
          :ok -> {:error, "Expected connection rejection but got success"}
        end
      end),
      test("AUTH: invalid username rejected", fn ->
        result =
          run_cmd(
            "mosquitto_pub",
            base ++
              ["-u", "wrong_user", "-P", "valid_pass", "-t", "auth/fail2", "-m", "should-fail"]
          )

        case result do
          {:error, _} -> :ok
          :ok -> {:error, "Expected connection rejection but got success"}
        end
      end),
      test("AUTH: no credentials rejected", fn ->
        result = run_cmd("mosquitto_pub", base ++ ["-t", "auth/fail3", "-m", "should-fail"])

        case result do
          {:error, _} -> :ok
          :ok -> {:error, "Expected connection rejection but got success"}
        end
      end)
    ]

    IO.puts("")
    results
  end

  # -----------------------------------------------------------------------
  # Cross-transport (verify both transports work identically)
  # -----------------------------------------------------------------------
  defp run_cross_transport_suite(tcp_port, ws_port) do
    IO.puts(
      "--- CROSS: TCP publisher → WS subscriber (same broker not possible, separate validation) ---\n"
    )

    # Note: TCP and WS are separate broker instances, so cross-transport pub/sub
    # requires same broker. We test that both brokers handle the same operations identically.

    results = [
      test("CROSS: TCP and WS handle same topic identically", fn ->
        # Publish on TCP
        :ok =
          run_cmd("mosquitto_pub", [
            "-h",
            "127.0.0.1",
            "-p",
            "#{tcp_port}",
            "-t",
            "cross/same",
            "-m",
            "via-tcp",
            "-r"
          ])

        Process.sleep(200)
        # Subscribe on TCP — should get retained
        sub1 =
          async_sub([
            "-h",
            "127.0.0.1",
            "-p",
            "#{tcp_port}",
            "-t",
            "cross/same",
            "-C",
            "1",
            "-W",
            "3"
          ])

        r1 = expect_exact(sub1, "via-tcp")

        # Publish on WS
        :ok =
          run_cmd("mosquitto_pub", [
            "--ws",
            "-h",
            "127.0.0.1",
            "-p",
            "#{ws_port}",
            "-t",
            "cross/same",
            "-m",
            "via-ws",
            "-r"
          ])

        Process.sleep(200)
        # Subscribe on WS — should get retained
        sub2 =
          async_sub([
            "--ws",
            "-h",
            "127.0.0.1",
            "-p",
            "#{ws_port}",
            "-t",
            "cross/same",
            "-C",
            "1",
            "-W",
            "3"
          ])

        r2 = expect_exact(sub2, "via-ws")

        if r1 == :ok and r2 == :ok,
          do: :ok,
          else: {:error, "TCP: #{inspect(r1)}, WS: #{inspect(r2)}"}
      end)
    ]

    IO.puts("")
    results
  end

  # -----------------------------------------------------------------------
  # Protocol version suite
  # -----------------------------------------------------------------------
  defp run_protocol_version_suite(port) do
    IO.puts("--- PROTOCOL: Version Compatibility ---\n")

    base = ["-h", "127.0.0.1", "-p", "#{port}"]

    results = [
      test("PROTO: MQTT 3.1 (mqttv31)", fn ->
        run_cmd("mosquitto_pub", base ++ ["-V", "mqttv31", "-t", "proto/v31", "-m", "v31-test"])
      end),
      test("PROTO: MQTT 3.1.1 (default)", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++ ["-V", "mqttv311", "-t", "proto/v311", "-m", "v311-test"]
        )
      end),
      test("PROTO: MQTT 5.0", fn ->
        run_cmd("mosquitto_pub", base ++ ["-V", "5", "-t", "proto/v5", "-m", "v5-test"])
      end),
      test("PROTO: MQTT 5.0 pub/sub round-trip", fn ->
        sub_task = async_sub(base ++ ["-V", "5", "-t", "proto/v5/rt", "-C", "1", "-W", "5"])
        Process.sleep(500)
        run_cmd("mosquitto_pub", base ++ ["-V", "5", "-t", "proto/v5/rt", "-m", "v5-roundtrip"])
        expect_exact(sub_task, "v5-roundtrip")
      end),
      test("PROTO: MQTT 5.0 with user property", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++
            [
              "-V",
              "5",
              "-t",
              "proto/v5/props",
              "-m",
              "props-test",
              "-D",
              "publish",
              "user-property",
              "key1",
              "value1"
            ]
        )
      end),
      test("PROTO: MQTT 5.0 with content type", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++
            [
              "-V",
              "5",
              "-t",
              "proto/v5/content",
              "-m",
              ~s({"data": true}),
              "-D",
              "publish",
              "content-type",
              "application/json"
            ]
        )
      end),
      test("PROTO: MQTT 5.0 with message expiry", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++
            [
              "-V",
              "5",
              "-t",
              "proto/v5/expiry",
              "-m",
              "expiring",
              "-D",
              "publish",
              "message-expiry-interval",
              "60"
            ]
        )
      end),
      test("PROTO: MQTT 5.0 with response topic and correlation data", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++
            [
              "-V",
              "5",
              "-t",
              "proto/v5/reqresp",
              "-m",
              "request",
              "-D",
              "publish",
              "response-topic",
              "proto/v5/response",
              "-D",
              "publish",
              "correlation-data",
              "req-123"
            ]
        )
      end),
      test("PROTO: MQTT 5.0 session expiry", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++ ["-V", "5", "-t", "proto/v5/sessexp", "-m", "session-test", "-x", "60"]
        )
      end),
      test("PROTO: MQTT 5.0 clean start + session expiry 0", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++ ["-V", "5", "-t", "proto/v5/cleanstart", "-m", "clean-test", "-x", "0"]
        )
      end),
      test("PROTO: MQTT 5.0 topic alias", fn ->
        run_cmd(
          "mosquitto_pub",
          base ++
            ["-V", "5", "-t", "proto/v5/ta", "-m", "ta-msg", "-D", "publish", "topic-alias", "1"]
        )
      end)
    ]

    IO.puts("")
    results
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp pubsub_roundtrip(base_sub, base_pub, topic, payload, sub_qos, pub_qos) do
    pubsub_roundtrip_raw(base_sub, base_pub, topic, payload, sub_qos, pub_qos, fn output ->
      String.trim(output) == payload
    end)
  end

  defp pubsub_roundtrip_raw(base_sub, base_pub, topic, payload, sub_qos, pub_qos, verify_fn) do
    sub_task = async_sub(base_sub ++ ["-t", topic, "-q", "#{sub_qos}", "-C", "1", "-W", "5"])
    Process.sleep(500)
    run_cmd("mosquitto_pub", base_pub ++ ["-t", topic, "-m", payload, "-q", "#{pub_qos}"])
    {output, exit_code} = Task.await(sub_task, 10_000)

    if exit_code == 0 and verify_fn.(output) do
      :ok
    else
      {:error, "exit=#{exit_code}, output=#{inspect(String.slice(String.trim(output), 0..100))}"}
    end
  end

  defp multi_message_test(base_sub, base_pub, topic, count) do
    sub_task = async_sub(base_sub ++ ["-t", topic, "-C", "#{count}", "-W", "10"])
    Process.sleep(500)

    for i <- 1..count do
      run_cmd("mosquitto_pub", base_pub ++ ["-t", topic, "-m", "msg-#{i}"])
      Process.sleep(20)
    end

    expect_lines(sub_task, count)
  end

  defp async_sub(args) do
    Task.async(fn ->
      System.cmd("mosquitto_sub", args, stderr_to_stdout: true)
    end)
  end

  defp expect_exact(task, expected) do
    {output, exit_code} = Task.await(task, 15_000)

    if exit_code == 0 and String.trim(output) == expected do
      :ok
    else
      {:error,
       "Expected #{inspect(expected)}, got #{inspect(String.trim(output))} (exit: #{exit_code})"}
    end
  end

  defp expect_lines(task, count) do
    {output, exit_code} = Task.await(task, 15_000)
    lines = output |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

    if exit_code == 0 and length(lines) == count do
      :ok
    else
      {:error,
       "Expected #{count} lines, got #{length(lines)} (exit: #{exit_code}): #{inspect(Enum.take(lines, 5))}"}
    end
  end

  defp expect_timeout(task) do
    {output, exit_code} = Task.await(task, 10_000)
    trimmed = String.trim(output)

    if exit_code == 27 or trimmed == "" or String.contains?(trimmed, "Timed out") do
      :ok
    else
      {:error, "Expected timeout/no messages, got #{inspect(trimmed)} (exit: #{exit_code})"}
    end
  end

  defp test(name, fun) do
    IO.write("  #{name}... ")

    try do
      case fun.() do
        :ok ->
          IO.puts("PASS")
          {name, :pass}

        {:error, reason} ->
          IO.puts("FAIL: #{reason}")
          {name, :fail}
      end
    rescue
      e ->
        IO.puts("FAIL: #{Exception.message(e)}")
        {name, :fail}
    catch
      kind, reason ->
        IO.puts("FAIL: #{inspect(kind)}: #{inspect(reason)}")
        {name, :fail}
    end
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "exit code #{code}: #{String.trim(output)}"}
    end
  end

  # Connect to broker with a will message using raw TCP/WS, wait for CONNACK, then abruptly close.
  # This simulates an ungraceful disconnect (no DISCONNECT packet sent).
  defp raw_connect_with_will_then_crash(port, ws_flags, opts) do
    will_topic = Keyword.fetch!(opts, :will_topic)
    will_payload = Keyword.fetch!(opts, :will_payload)
    will_qos = Keyword.get(opts, :will_qos, 0)
    client_id = Keyword.get(opts, :client_id, "raw-will-client")

    connect_packet = %{
      type: :connect,
      protocol_version: 4,
      client_id: client_id,
      username: nil,
      password: nil,
      will: %{
        topic: will_topic,
        payload: will_payload,
        qos: will_qos,
        retain: false
      },
      clean_session: true,
      keep_alive: 0,
      properties: %{}
    }

    {:ok, data} = MqttX.Packet.Codec.encode(4, connect_packet)
    binary_data = IO.iodata_to_binary(data)

    if "--ws" in ws_flags do
      raw_ws_connect_and_crash(port, binary_data)
    else
      raw_tcp_connect_and_crash(port, binary_data)
    end
  end

  defp raw_tcp_connect_and_crash(port, connect_data) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    :ok = :gen_tcp.send(socket, connect_data)
    # Wait for CONNACK
    {:ok, _connack} = :gen_tcp.recv(socket, 0, 5000)
    # Small delay to ensure server has fully processed the connection
    Process.sleep(100)
    # Abruptly close - no DISCONNECT packet sent
    :gen_tcp.close(socket)
  end

  defp raw_ws_connect_and_crash(port, connect_data) do
    import Bitwise
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)

    # WebSocket upgrade handshake
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET /mqtt HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Protocol: mqtt\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
    true = String.contains?(response, "101")

    # Send MQTT CONNECT as a WebSocket binary frame
    len = byte_size(connect_data)
    mask_key = :crypto.strong_rand_bytes(4)
    mask_bytes = :binary.copy(mask_key, div(len, 4) + 1)
    masked = :crypto.exor(connect_data, binary_part(mask_bytes, 0, len))

    frame =
      if len < 126 do
        <<0x82, bor(0x80, len), mask_key::binary, masked::binary>>
      else
        <<0x82, 0xFE, len::16, mask_key::binary, masked::binary>>
      end

    :ok = :gen_tcp.send(socket, frame)
    # Wait for CONNACK (WebSocket frame)
    {:ok, _connack_frame} = :gen_tcp.recv(socket, 0, 5000)
    Process.sleep(100)
    # Abruptly close - no DISCONNECT
    :gen_tcp.close(socket)
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp print_summary(results) do
    IO.puts("\n================================================================")
    IO.puts("  Results Summary")
    IO.puts("================================================================\n")

    # Group by prefix
    groups =
      Enum.group_by(results, fn {name, _} ->
        name |> String.split(":") |> hd() |> String.trim()
      end)

    for {group, items} <- Enum.sort(groups) do
      passed = Enum.count(items, fn {_, s} -> s == :pass end)
      total = length(items)
      IO.puts("  #{group}: #{passed}/#{total}")

      for {name, status} <- items do
        icon = if status == :pass, do: "PASS", else: "FAIL"
        IO.puts("    [#{icon}] #{name}")
      end

      IO.puts("")
    end

    total_passed = Enum.count(results, fn {_, s} -> s == :pass end)
    total_failed = Enum.count(results, fn {_, s} -> s == :fail end)
    total = length(results)

    IO.puts("  TOTAL: #{total_passed} passed, #{total_failed} failed out of #{total} tests")

    if total_failed > 0 do
      IO.puts("\n  ❌ VALIDATION FAILED")
    else
      IO.puts("\n  ✅ ALL VALIDATIONS PASSED")
    end
  end
end

Validation.run()
