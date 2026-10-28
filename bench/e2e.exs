# End-to-end throughput over real sockets on loopback: MqttX clients against
# an MqttX broker.
#
#     mix run bench/e2e.exs
#     BENCH_TRANSPORT=ws mix run bench/e2e.exs      # MQTT over WebSocket
#
# Environment: BENCH_TIME (seconds per scenario, default 3), BENCH_SUBSCRIBERS
# (fan-out width, default 50), BENCH_PAYLOADS (a comma-separated subset of
# "100 B", "4 KiB", "64 KiB"; all three by default — the whole run is long,
# and a before/after comparison of one size wants several interleaved runs).
#
# Scenarios, each over 100 B / 4 KiB / 64 KiB payloads:
#   uplink QoS 0  — one publisher, the broker's handle_publish counts arrivals
#   uplink QoS 1  — same, every message PUBACKed (client max_inflight: 100)
#   fan-out QoS 0 — one PUBLISH is forwarded to N subscribed connections by a
#                   handle_info publish tuple each (the PubSub-bridge pattern)
#   fan-out via deliver — the same N deliveries through MqttX.Server.deliver/3
#
# Benchee times one batch per iteration; the summary at the end converts that
# to messages (or deliveries) per second and MB/s.

Logger.configure(level: :warning)

bench_time = String.to_integer(System.get_env("BENCH_TIME", "3"))
subscribers = String.to_integer(System.get_env("BENCH_SUBSCRIBERS", "50"))
transport = if System.get_env("BENCH_TRANSPORT") == "ws", do: :ws, else: :tcp

defmodule Bench.Broker do
  @moduledoc false
  use MqttX.Server

  # Counts every accepted PUBLISH. Publishes under bench/fanout/ are forwarded
  # to every connection that subscribed — the PubSub-bridge pattern from the
  # README, minus PubSub — so the uplink scenarios measure uplink alone.
  def init(opts), do: %{counter: Keyword.fetch!(opts, :counter)}

  def handle_connect(_client_id, _credentials, state), do: {:ok, state}

  def handle_subscribe(topics, state) do
    Registry.register(Bench.Registry, :subscribers, nil)
    {:ok, Enum.map(topics, & &1.qos), state}
  end

  def handle_publish(["bench", "fanout" | _] = topic, payload, opts, state) do
    :counters.add(state.counter, 1, 1)

    Registry.dispatch(Bench.Registry, :subscribers, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:fanout, topic, payload, opts.qos})
    end)

    {:ok, state}
  end

  # The broker's own fan-out: MqttX.Server.deliver/3 matches every session's
  # subscriptions in the listener's ETS index and queues for each connection
  # before poking it, so this measures the full deliver path
  def handle_publish(["bench", "deliver" | _] = topic, payload, opts, state) do
    :counters.add(state.counter, 1, 1)
    {:ok, _} = MqttX.Server.deliver(topic, payload, %{qos: opts.qos})
    {:ok, state}
  end

  def handle_publish(_topic, _payload, _opts, state) do
    :counters.add(state.counter, 1, 1)
    {:ok, state}
  end

  def handle_info({:fanout, topic, payload, qos}, state) do
    {:publish, topic, payload, %{qos: qos, retain: false}, state}
  end

  def handle_disconnect(_reason, _state), do: :ok
end

defmodule Bench.Subscriber do
  @moduledoc false
  def handle_mqtt_event(:message, _message, %{counter: counter} = state) do
    :counters.add(counter, 1, 1)
    state
  end

  def handle_mqtt_event(:disconnected, reason, state) do
    IO.puts("!! subscriber disconnected: #{inspect(reason)}")
    state
  end

  def handle_mqtt_event(_event, _data, state), do: state
end

defmodule Bench.E2E do
  @moduledoc false

  def await(counter, target, deadline_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    spin(counter, target, deadline)
  end

  defp spin(counter, target, deadline) do
    cond do
      :counters.get(counter, 1) >= target ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out: #{:counters.get(counter, 1)}/#{target} messages arrived"

      true ->
        Process.sleep(1)
        spin(counter, target, deadline)
    end
  end

  # Publish `n` messages, waiting out client-side flow control (QoS 1/2)
  def publish_batch(client, topic, payload, qos, n) do
    Enum.each(1..n, fn _ -> publish(client, topic, payload, qos) end)
  end

  defp publish(client, topic, payload, qos) do
    case MqttX.Client.publish(client, topic, payload, qos: qos) do
      :ok ->
        :ok

      {:error, :flow_control} ->
        Process.sleep(1)
        publish(client, topic, payload, qos)

      {:error, reason} ->
        raise "publish failed: #{inspect(reason)}"
    end
  end
end

# --- broker ---------------------------------------------------------------

{:ok, _} = Registry.start_link(keys: :duplicate, name: Bench.Registry)
received = :counters.new(1, [:write_concurrency])

{:ok, listen} = :gen_tcp.listen(0, [])
{:ok, port} = :inet.port(listen)
:gen_tcp.close(listen)

server_transport =
  case transport do
    :tcp -> MqttX.Transport.ThousandIsland
    :ws -> MqttX.Transport.WebSocket
  end

{:ok, _server} =
  MqttX.Server.start_link(Bench.Broker, [counter: received],
    port: port,
    transport: server_transport,
    transport_opts: %{max_packet_size: 2 * 1024 * 1024}
  )

Process.sleep(200)

# --- clients --------------------------------------------------------------

connect = fn client_id, handler_state ->
  {:ok, client} =
    MqttX.Client.connect(
      host: "127.0.0.1",
      port: port,
      client_id: client_id,
      transport: transport,
      protocol_version: 5,
      await_connect: true,
      max_packet_size: 2 * 1024 * 1024,
      handler: Bench.Subscriber,
      handler_state: handler_state
    )

  client
end

delivered = :counters.new(1, [:write_concurrency])
publisher = connect.("bench-publisher", %{counter: delivered})

subscriber_clients =
  for i <- 1..subscribers do
    client = connect.("bench-subscriber-#{i}", %{counter: delivered})
    {:ok, [1]} = MqttX.Client.subscribe(client, "bench/fanout/#", qos: 1)
    {:ok, [1]} = MqttX.Client.subscribe(client, "bench/deliver/#", qos: 1)
    client
  end

IO.puts(
  "broker on 127.0.0.1:#{port} (#{transport}), 1 publisher, #{subscribers} subscribers, " <>
    "#{bench_time}s per scenario"
)

# Batch sizes keep each iteration in the tens of milliseconds
payloads = System.get_env("BENCH_PAYLOADS", "100 B,4 KiB,64 KiB") |> String.split(",")

inputs =
  %{
    "100 B" => {:binary.copy(<<"x">>, 100), 1_000},
    "4 KiB" => {:binary.copy(<<"x">>, 4_096), 500},
    "64 KiB" => {:binary.copy(<<"x">>, 65_536), 50}
  }
  |> Map.filter(fn {name, _} -> name in payloads end)

if inputs == %{}, do: raise("BENCH_PAYLOADS names none of \"100 B\", \"4 KiB\", \"64 KiB\"")

uplink = fn qos ->
  fn {payload, batch} ->
    start = :counters.get(received, 1)
    Bench.E2E.publish_batch(publisher, "bench/uplink", payload, qos, batch)
    Bench.E2E.await(received, start + batch)
  end
end

fanout = fn {payload, batch} ->
  start = :counters.get(delivered, 1)
  Bench.E2E.publish_batch(publisher, "bench/fanout/t", payload, 0, batch)
  Bench.E2E.await(delivered, start + batch * subscribers)
end

fanout_deliver = fn {payload, batch} ->
  start = :counters.get(delivered, 1)
  Bench.E2E.publish_batch(publisher, "bench/deliver/t", payload, 0, batch)
  Bench.E2E.await(delivered, start + batch * subscribers)
end

suite =
  Benchee.run(
    %{
      "uplink QoS 0" => uplink.(0),
      "uplink QoS 1" => uplink.(1),
      "fan-out QoS 0, 1 -> #{subscribers}" => fanout,
      "fan-out via deliver, 1 -> #{subscribers}" => fanout_deliver
    },
    inputs: inputs,
    warmup: 1,
    time: bench_time,
    print: [configuration: false]
  )

# --- summary ----------------------------------------------------------------

IO.puts("\n== throughput ==\n")

IO.puts(
  String.pad_trailing("scenario", 30) <> String.pad_trailing("payload", 9) <> "   msg/s      MB/s"
)

for scenario <- suite.scenarios do
  {payload, batch} = inputs[scenario.input_name]
  seconds = scenario.run_time_data.statistics.average / 1_000_000_000
  multiplier = if String.starts_with?(scenario.job_name, "fan-out"), do: subscribers, else: 1
  messages = batch * multiplier / seconds
  mb = messages * byte_size(payload) / 1_000_000

  IO.puts(
    String.pad_trailing(scenario.job_name, 30) <>
      String.pad_trailing(scenario.input_name, 9) <>
      String.pad_leading(:erlang.float_to_binary(messages, decimals: 0), 8) <>
      String.pad_leading(:erlang.float_to_binary(mb, decimals: 1), 10)
  )
end

Enum.each([publisher | subscriber_clients], &MqttX.Client.disconnect/1)
