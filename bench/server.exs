# Broker-side data-structure benchmarks: the subscription router, the retained
# store, and receive-buffer reassembly.
#
#     mix run bench/server.exs
#
# Each group is a separate Benchee run with its own inputs.

alias MqttX.Packet.Codec
alias MqttX.Server.RetainedStore
alias MqttX.Server.Router
alias MqttX.Transport.Handler

Logger.configure(level: :warning)
bench_time = String.to_integer(System.get_env("BENCH_TIME", "2"))

# ----------------------------------------------------------------------------
# Router: match a topic against N subscriptions spread over N/10 clients, with
# a mix of exact, `+` and `#` filters. Cost should be O(depth + matches),
# independent of N.
# ----------------------------------------------------------------------------

build_router = fn subscriptions ->
  Enum.reduce(1..subscriptions, Router.new(), fn i, router ->
    client = {:client, rem(i, max(div(subscriptions, 10), 1))}

    filter =
      case rem(i, 10) do
        0 -> "tenant#{rem(i, 100)}/+/temperature"
        1 -> "tenant#{rem(i, 100)}/#"
        _ -> "tenant#{rem(i, 100)}/device#{i}/temperature"
      end

    Router.subscribe(router, filter, client, qos: rem(i, 3))
  end)
end

IO.puts("\n== Router.match/2 ==")

Benchee.run(
  %{
    "match, exact hit" => fn router -> Router.match(router, "tenant42/device42/temperature") end,
    "match, wildcard hits only" => fn router ->
      Router.match(router, "tenant42/device-unknown/temperature")
    end,
    "match, no subscribers" => fn router -> Router.match(router, "nobody/listens/here") end
  },
  inputs: %{
    "1k subscriptions" => build_router.(1_000),
    "10k subscriptions" => build_router.(10_000),
    "100k subscriptions" => build_router.(100_000)
  },
  warmup: 1,
  time: bench_time,
  print: [configuration: false]
)

# ----------------------------------------------------------------------------
# Retained store: deliver-on-subscribe lookups against a 100k-topic store.
# A literal prefix bounds the ETS traversal; a lone `#` must return everything.
# ----------------------------------------------------------------------------

retained = RetainedStore.new_table()

for tenant <- 1..100,
    device <- 1..100,
    metric <- ~w(temp humidity level pressure battery co2 lux motion door rssi) do
  RetainedStore.store(retained, "tenant#{tenant}/device#{device}/#{metric}", "v", 0, %{}, nil)
end

IO.puts("\n== RetainedStore.match/2 (100k retained topics) ==")

Benchee.run(
  %{
    "exact topic" => fn -> RetainedStore.match(retained, "tenant42/device7/temp") end,
    "tenant42/+/temp (100 hits)" => fn -> RetainedStore.match(retained, "tenant42/+/temp") end,
    "tenant42/device7/# (10 hits)" => fn ->
      RetainedStore.match(retained, "tenant42/device7/#")
    end,
    "+/device7/temp (100 hits, unbounded scan)" => fn ->
      RetainedStore.match(retained, "+/device7/temp")
    end,
    "# (everything)" => fn -> RetainedStore.match(retained, "#") end
  },
  warmup: 1,
  time: bench_time,
  print: [configuration: false]
)

# ----------------------------------------------------------------------------
# Receive buffer: a single large PUBLISH delivered to the broker handler in
# 1460-byte segments. Cost should be linear in the packet size.
# ----------------------------------------------------------------------------

defmodule Bench.NullHandler do
  use MqttX.Server
  def init(_), do: %{}
  def handle_connect(_id, _creds, state), do: {:ok, state}
  def handle_publish(_t, _p, _o, state), do: {:ok, state}
  def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
  def handle_disconnect(_r, _s), do: :ok
end

connected_handler = fn ->
  opts = [transport_opts: %{max_packet_size: :infinity}]

  {:ok, state} =
    Handler.init(Bench.NullHandler, opts, RetainedStore.new_table(), nil, fn _ -> :ok end)

  {:ok, connect} =
    Codec.encode(4, %{
      type: :connect,
      protocol_version: 4,
      client_id: "bench-#{System.unique_integer([:positive])}",
      username: nil,
      password: nil,
      will: nil,
      clean_session: true,
      keep_alive: 0,
      properties: %{}
    })

  {:ok, state} = Handler.handle_data(connect, state)
  state
end

segments = fn payload_bytes ->
  {:ok, packet} =
    Codec.encode(4, %{
      type: :publish,
      topic: "bench/large",
      payload: :binary.copy(<<0>>, payload_bytes),
      qos: 0,
      retain: false,
      dup: false,
      packet_id: nil,
      properties: %{}
    })

  for <<segment::binary-size(1460) <- IO.iodata_to_binary(packet)>>, do: segment
end

IO.puts("\n== Handler.handle_data/2, one PUBLISH in 1460-byte segments ==")

Benchee.run(
  %{
    "reassemble" => fn {state, parts} ->
      Enum.reduce(parts, state, fn part, st ->
        {:ok, st} = Handler.handle_data(part, st)
        st
      end)
    end
  },
  inputs: %{
    "256 KiB" => {connected_handler.(), segments.(256 * 1024)},
    "1 MiB (default limit)" => {connected_handler.(), segments.(1024 * 1024)},
    "16 MiB" => {connected_handler.(), segments.(16 * 1024 * 1024)}
  },
  warmup: 1,
  time: bench_time,
  print: [configuration: false]
)
