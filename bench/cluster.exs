# Delivery throughput across a two-node cluster: publishers on this node call
# MqttX.Server.deliver/4, subscribers are MqttX clients over loopback TCP,
# connected to this node, to a peer node (a :peer on the same machine) or to
# both. The single-node run is the baseline.
#
#     mix run bench/cluster.exs
#
# Environment: BENCH_MESSAGES (per publisher, default 2000), BENCH_PUBLISHERS
# (default 4), BENCH_SUBSCRIBERS (default 10), BENCH_QOS (default 1),
# BENCH_PAYLOAD (bytes, default 100).
#
# Each subscriber's outbound queue holds 10000 messages: past that the broker
# drops (a slow consumer), so publishers x messages stays below it.
#
# Needs Erlang distribution (epmd). Both nodes share this machine's cores, so
# the numbers measure the cluster path's cost, not a cluster's capacity.

Logger.configure(level: :warning)

messages = String.to_integer(System.get_env("BENCH_MESSAGES", "2000"))
publishers = String.to_integer(System.get_env("BENCH_PUBLISHERS", "4"))
subscribers = String.to_integer(System.get_env("BENCH_SUBSCRIBERS", "10"))
qos = String.to_integer(System.get_env("BENCH_QOS", "1"))
payload = :binary.copy(<<"x">>, String.to_integer(System.get_env("BENCH_PAYLOAD", "100")))

{:module, broker, broker_binary, _} =
  defmodule Bench.ClusterBroker do
    @moduledoc false
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_disconnect(_reason, _state), do: :ok

    # Keeps a listener alive past the :erpc call that starts it
    def start_listener(name, port) do
      parent = self()

      spawn(fn ->
        {:ok, _} = MqttX.Server.start_link(__MODULE__, [], name: name, port: port)
        send(parent, :started)
        Process.sleep(:infinity)
      end)

      receive do
        :started -> :ok
      after
        5_000 -> raise "listener did not start"
      end
    end
  end

defmodule Bench.Counter do
  @moduledoc false
  def handle_mqtt_event(:message, _message, %{counter: counter} = state) do
    :counters.add(counter, 1, 1)
    state
  end

  def handle_mqtt_event(_event, _data, state), do: state
end

# --- nodes ------------------------------------------------------------------

_ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
{:ok, _} = :net_kernel.start([:"mqttx_bench_#{System.unique_integer([:positive])}", :shortnames])

{:ok, _peer, peer} =
  :peer.start_link(%{name: :"mqttx_bench_peer_#{System.unique_integer([:positive])}"})

:ok = :erpc.call(peer, :code, :add_paths, [:code.get_path()])
:ok = :erpc.call(peer, Logger, :configure, [[level: :warning]])
{:ok, _} = :erpc.call(peer, Application, :ensure_all_started, [:mqttx])
{:ok, _} = :erpc.call(peer, Application, :ensure_all_started, [:thousand_island])
{:module, _} = :erpc.call(peer, :code, :load_binary, [broker, ~c"nofile", broker_binary])

free_port = fn ->
  {:ok, listen} = :gen_tcp.listen(0, [])
  {:ok, port} = :inet.port(listen)
  :gen_tcp.close(listen)
  port
end

# A listener named `name` on this node and, when `clustered`, on the peer
start = fn name, clustered ->
  local = free_port.()
  :ok = broker.start_listener(name, local)

  if clustered do
    remote = free_port.()
    :ok = :erpc.call(peer, broker, :start_listener, [name, remote])

    wait = fn wait ->
      if length(MqttX.Server.Cluster.members(name)) < 2,
        do:
          (
            Process.sleep(10)
            wait.(wait)
          )
    end

    wait.(wait)
    {local, remote}
  else
    {local, nil}
  end
end

connect = fn port, client_id, counter ->
  {:ok, client} =
    MqttX.Client.connect(
      host: "127.0.0.1",
      port: port,
      client_id: client_id,
      protocol_version: 5,
      await_connect: true,
      handler: Bench.Counter,
      handler_state: %{counter: counter}
    )

  {:ok, [^qos]} = MqttX.Client.subscribe(client, "bench/#", qos: qos)
  client
end

# --- one run ----------------------------------------------------------------

run = fn label, clustered, ports ->
  name = :"bench_#{System.unique_integer([:positive])}"
  {local, remote} = start.(name, clustered)
  counter = :counters.new(1, [:write_concurrency])

  clients =
    for i <- 1..subscribers do
      port =
        case Enum.at(ports, rem(i, length(ports))) do
          :local -> local
          :remote -> remote
        end

      connect.(port, "bench-sub-#{name}-#{i}", counter)
    end

  # Routes reach the publishing node asynchronously
  Process.sleep(300)

  target = messages * publishers * subscribers
  started = System.monotonic_time(:microsecond)

  for _ <- 1..publishers do
    spawn_link(fn ->
      for _ <- 1..messages,
          do: {:ok, _} = MqttX.Server.deliver(name, "bench/t", payload, %{qos: qos})
    end)
  end

  wait = fn wait ->
    received = :counters.get(counter, 1)

    cond do
      received >= target ->
        :ok

      System.monotonic_time(:microsecond) - started > 120_000_000 ->
        IO.puts("!! #{label}: only #{received}/#{target} arrived")

      true ->
        Process.sleep(5)
        wait.(wait)
    end
  end

  wait.(wait)
  seconds = (System.monotonic_time(:microsecond) - started) / 1_000_000
  Enum.each(clients, &MqttX.Client.disconnect/1)

  IO.puts(
    String.pad_trailing(label, 40) <>
      String.pad_leading(:erlang.float_to_binary(target / seconds, decimals: 0), 10) <>
      String.pad_leading(:erlang.float_to_binary(seconds, decimals: 2), 9)
  )
end

IO.puts(
  "#{publishers} publishers x #{messages} messages, #{subscribers} subscribers, " <>
    "QoS #{qos}, #{byte_size(payload)} B payload\n"
)

IO.puts(String.pad_trailing("subscribers", 40) <> "  deliv/s  seconds")
run.("single node", false, [:local])
run.("cluster, all on this node", true, [:local])
run.("cluster, all on the peer", true, [:remote])
run.("cluster, half on each node", true, [:local, :remote])
