# Performance & Scaling

MqttX is architected to scale from tens of thousands to roughly a million concurrent device connections on a single BEAM node, depending on hardware and workload — see [Capacity Planning](#capacity-planning) for what each instance size actually supports and where the ceiling comes from. This guide explains the architectural decisions and optimizations that make this possible.

## Architecture Overview

Each MQTT connection is a lightweight Erlang process (~2KB initial heap, ~20KB total with connection state and socket overhead). The BEAM VM's preemptive scheduler distributes these processes across all available CPU cores. At 100k connections, connection state alone is roughly 2GB; size the machine above that — see [Capacity Planning](#capacity-planning) for the headroom a real deployment needs.

The key bottlenecks at scale are not the number of connections, but the **hot paths** that execute on every message:

| Hot Path | Frequency | Optimization |
|----------|-----------|--------------|
| Topic matching | Every PUBLISH | Trie-based router: O(L+K) vs O(N) |
| Packet encoding | Every outgoing packet | iodata output, zero binary copy |
| Buffer handling | Every TCP chunk | Wait for the declared length; assemble once |
| Callback dispatch | Every incoming packet | Cached `function_exported?` |
| Flow control check | Every QoS 1/2 publish | Direct counter vs O(N) scan |
| Retained delivery | Every SUBSCRIBE | ETS match spec per filter, prefix-bounded |

## Topic Router

The router uses a **trie (prefix tree)** keyed by topic segments. Given a subscription to `sensors/+/temperature`, the trie looks like:

```text
root
└── "sensors"
    └── :single_level  (+)
        └── "temperature"
            └── subscribers: %{client1 => %{qos: 1}}
```

**Matching** walks the trie, branching into up to 3 children at each level: exact segment match, single-level wildcard (`+`), and multi-level wildcard (`#`). This is O(L + K) where L is the topic depth and K is the total matching subscribers — independent of total subscription count.

**Impact at scale:**

| Subscriptions | Linear scan (old) | Trie (new) | Speedup |
|--------------|-------------------|------------|---------|
| 1,000 | 1,000 comparisons | ~3-5 lookups | ~200x |
| 10,000 | 10,000 comparisons | ~3-5 lookups | ~2,000x |
| 100,000 | 100,000 comparisons | ~3-5 lookups | ~20,000x |

The trie also stores a `by_client` index mapping each client to its subscriptions, making `unsubscribe_all` (client disconnect cleanup) efficient without scanning the entire subscription list.

## Packet Encoding

All socket sends use `Codec.encode_iodata/2` which returns an iolist — a nested list of binaries that `:gen_tcp.send/2` and `:ssl.send/2` accept natively. This avoids a final `IO.iodata_to_binary/1` copy.

For a typical 50-byte PUBLISH packet, this saves one 50-byte allocation and copy per send. At 100k messages/second, that's 5MB/s of avoided garbage collection pressure.

**Codec benchmarks** (Apple M4 Pro):

| Operation | Throughput | Notes |
|-----------|-----------|-------|
| PUBLISH encode | 5.05M ops/s | 2.9x faster than mqtt_packet_map |
| SUBSCRIBE encode | 3.42M ops/s | 4.2x faster than mqtt_packet_map |
| PUBLISH decode | 2.36M ops/s | Zero-copy sub-binary references |

## Buffer Handling

TCP delivers data in arbitrarily-sized chunks. In the common case a complete MQTT packet arrives in one read and the receive buffer is empty, so the read is handed straight to the decoder — no copy — and the `rest` returned by `Codec.decode` is a zero-copy sub-binary of the original data.

The interesting case is a packet that spans many reads. The obvious `buffer <> data` followed by a decode attempt is quadratic: decoding pattern-matches the buffer, and a binary that has been matched loses the BEAM's in-place append optimization, so every read re-copies everything buffered so far. Instead, once the fixed header of an incomplete packet has arrived its total length is known, and `MqttX.Packet.Buffer` simply collects reads (an iolist cons per read — no copy, no match) until that many bytes are in hand, then flattens and decodes exactly once. The same buffer serves the broker, the client, and the client's WebSocket frame layer.

Measured on the broker, one PUBLISH arriving in 1460-byte segments (`bench/server.exs`):

| Packet | `buf <> data` per read | Declared-length reassembly |
|--------|------------------------|----------------------------|
| 1 MiB (default `max_packet_size`) | 22 ms | 0.3 ms |
| 4 MiB | 366 ms | 0.8 ms |
| 16 MiB | 7.1 s | 5 ms |

## Callback Dispatch

Elixir's `function_exported?/3` performs a module lookup on each call. For optional callbacks like `handle_info/2`, `handle_puback/2`, and `handle_mqtt_event/3`, this check runs on every incoming packet. MqttX computes these once at connection init:

```elixir
# Computed once in handle_connection/init:
handler_has_handle_info: function_exported?(handler, :handle_info, 2),
handler_has_handle_puback: function_exported?(handler, :handle_puback, 2)

# Then used as a simple boolean check per packet:
if state.handler_has_handle_puback do
  # ...
end
```

## Flow Control

MQTT 5.0's `receive_maximum` limits how many unacknowledged QoS 1/2 messages can be in flight simultaneously. Both client and server enforce this with a direct counter:

```elixir
# Server-side: check before accepting incoming QoS 2 PUBLISH
if state.inflight_count >= state.server_receive_maximum do
  # Send PUBREC with reason code 0x93 (Receive Maximum exceeded)
end
```

The counter is incremented when sending PUBREC (QoS 2 received) and decremented when sending PUBCOMP (QoS 2 complete) or when entries are dropped after max retries.

## Retained Message Delivery

When a client subscribes, the server delivers matching retained messages from an ETS `ordered_set` keyed by the topic's segment list (`MqttX.Server.RetainedStore`).

1. **Exact topic subscriptions** (no wildcards): the filter *is* the key — one `ets.lookup/2`.
2. **Wildcard subscriptions**: the filter compiles to a single ETS match spec — literal segments bound, `+` a wildcard segment, `#` a wildcard tail — so matching runs inside ETS, and a literal prefix bounds the traversal to that key range. A lone `#` is the one filter that must still visit everything.

Measured against 100,000 retained topics (`bench/server.exs`):

| Filter | Hits | Time |
|--------|------|------|
| `tenant42/device7/temp` (exact) | 1 | 0.4 µs |
| `tenant42/device7/#` | 10 | 2 µs |
| `tenant42/+/temp` | 100 | 88 µs |
| `+/device7/temp` (no literal prefix) | 100 | 2.8 ms |
| `#` | 100,000 | 19 ms |

## Measured Throughput

End-to-end over loopback, MqttX client against MqttX broker, Apple M4 Pro (64 GB), Elixir 1.20 / OTP 29 — `mix run bench/e2e.exs`. One publisher; "fan-out" is one PUBLISH forwarded to 50 subscribed connections through a `handle_info` publish tuple per connection, as in the PubSub-bridge pattern. Rates are per second; QoS 1 includes the round trip for every PUBACK, with the client's default `max_inflight: 100`.

| Scenario | 100 B | 4 KiB | 64 KiB |
|----------|-------|-------|--------|
| Uplink QoS 0, TCP | 164k msg/s | 100k msg/s (408 MB/s) | 25k msg/s (1.6 GB/s) |
| Uplink QoS 1, TCP | 98k msg/s | 82k msg/s | 18k msg/s (1.2 GB/s) |
| Fan-out 1 → 50, TCP | 450k deliveries/s | 425k deliveries/s (1.7 GB/s) | 117k deliveries/s (7.7 GB/s) |
| Uplink QoS 0, WebSocket | 153k msg/s | 58k msg/s | 7k msg/s (460 MB/s) |
| Uplink QoS 1, WebSocket | 77k msg/s | 45k msg/s | 6k msg/s |
| Fan-out 1 → 50, WebSocket | 478k deliveries/s | 447k deliveries/s | 102k deliveries/s (6.7 GB/s) |

The single-publisher uplink figures are bounded by one process doing a `GenServer.call` per publish; many publishers scale with cores. `test/mqttx/load_test.exs` (`mix test --include load`) runs the same shape with 20 concurrent QoS 1 publishers and a 1 → 20 fan-out, asserting that every message arrives exactly as often as it should and every QoS 1 publish is acknowledged.

## Capacity Planning

> **Read this first.** The numbers below are derived from architectural
> analysis plus the codec and end-to-end measurements above, all taken on
> one developer machine over loopback. Treat them as a starting point for
> your own measurements with `bench/e2e.exs`, not as guarantees. Real
> capacity depends on message sizes, subscription fan-out, retained-store
> size, TLS vs plaintext, and above all the work your handler callbacks do.

### Per-device resource usage

Budget roughly **20–25 KB of system RAM per connected device**, split between
the BEAM and the kernel:

| Component | Size | Where it lives |
|-----------|------|----------------|
| Process heap (BEAM base allocation) | ~2 KB | BEAM RSS |
| Connection state (client_id, flags, will, timers) | ~1 KB | BEAM RSS |
| Handler state (application-defined) | ~0.5–5 KB | BEAM RSS |
| Session data, pending acks, optional features | ~1–5 KB | BEAM RSS |
| Socket struct and BEAM-side buffers | ~2–5 KB | BEAM RSS |
| **Kernel socket buffers** (`rmem`/`wmem` minimums) | **~4–8 KB** | **Kernel, not BEAM RSS** |

The kernel share is the one most often forgotten: it does not appear in the
BEAM's memory reporting, but it comes out of the same machine's RAM. At 500K
connections it alone is 2–4 GB.

### Sizing method

Do not allocate 100% of RAM to connection state. A workable rule:

```text
devices ≈ (total_RAM × 0.60) / 22 KB
```

The 40% reserve covers the BEAM runtime itself, ETS tables (the retained-message
store — up to `:max_retained_messages`, 100K topics by default — plus the
subscription trie), the binary heap for in-flight payloads, OS page cache, and
headroom for reconnect storms, which transiently allocate far above steady
state. Machines sized to their steady-state ceiling fall over during exactly
the event you most need them to survive: a mass reconnect after a network blip.

### Instance sizing — idle-ish IoT (~1 msg/min)

| Instance | RAM-derived ceiling | Practical target | Binding constraint |
|----------|--------------------|--------------------|--------------------|
| 1 vCPU / 2 GB | ~55,000 | ~50,000 | RAM |
| 2 vCPU / 4 GB | ~110,000 | ~100,000 | RAM |
| 2 vCPU / 8 GB | ~225,000 | ~200,000 | RAM, `+Q` port limit |
| 4 vCPU / 16 GB | ~450,000 | ~400,000 | RAM, fds, kernel memory |
| 8 vCPU / 32 GB | ~900,000 | ~600,000 | fds, kernel memory, ETS contention |
| 16 vCPU / 128 GB | ~3,600,000 | ~1,000,000 | ETS contention, accept rate, failure domain |

The right-hand columns diverge on purpose. Below ~500K connections RAM is the
limit and the arithmetic holds. Above it the bottleneck moves somewhere else
entirely, and buying more RAM stops helping:

- **Kernel socket memory** grows with connections, not cores: 1M sockets is
  4–8 GB of kernel buffers on top of BEAM RSS.
- **Shared ETS tables** — the retained store and the subscription router are
  single tables every connection process reads. Read concurrency is enabled,
  but write-heavy retained or subscribe/unsubscribe churn contends regardless
  of how many cores you add.
- **Accept and handshake rate**, not steady state, is what fails first on a
  large node. A mass reconnect of 1M devices means 1M CONNECTs (and TLS
  handshakes, which are CPU-expensive) arriving in seconds.
- **Failure domain.** One node holding 1M devices is one restart away from a
  1M-device reconnect storm against itself.

For these reasons, past roughly 500K connections per node, **horizontal
scaling is usually the better engineering answer than a larger instance** —
several 8-vCPU nodes behind a load balancer beat one 16-vCPU node, and give
you somewhere to fail over to. See [Beyond a single node](#beyond-a-single-node).

Every row above ~65,000 connections requires raising the BEAM port limit
(`+Q`) and file-descriptor limits; rows above 262,144 also require `+P`. See
[VM Tuning](#vm-tuning) and [OS Tuning](#os-tuning) — these are not optional.

### Message-rate ceilings

When devices are chatty, CPU binds before RAM. Per-vCPU throughput, assuming
small (≈50-byte) QoS 0 payloads and a handler that does negligible work:

| Device activity | Devices per vCPU | Bottleneck |
|-----------------|------------------|------------|
| Sleepy sensors (1 msg/min) | ~50K–100K | RAM |
| Normal IoT (1 msg/30s) | ~30K–80K | RAM |
| Chatty devices (1 msg/sec) | ~10K–15K | CPU |
| Real-time streaming (10 msg/sec) | ~1K–2K | CPU |

Scaling across cores is **sub-linear** — assume roughly 80–85% efficiency per
doubling beyond 4 vCPUs, due to scheduler rebalancing, per-process GC pauses,
and ETS contention:

| Instance | Devices @ 1 msg/sec | Devices @ 10 msg/sec |
|----------|---------------------|----------------------|
| 1 vCPU | ~15,000 | ~1,500 |
| 2 vCPU | ~30,000 | ~3,000 |
| 4 vCPU | ~60,000 | ~6,000 |
| 8 vCPU | ~100,000 | ~10,000 |
| 16 vCPU | ~160,000 | ~16,000 |

These assume plaintext TCP. TLS adds per-handshake CPU cost (significant
during reconnect storms) and a smaller per-message cost; budget conservatively
if devices reconnect frequently on flaky cellular links.

### System-level constraints

At high connection counts, OS and kernel limits usually bind before BEAM ones:

- **File descriptors**: one per connection. Raise `ulimit -n` above your target
  (see [OS Tuning](#os-tuning)).
- **BEAM port limit**: every socket is a port, and the default is only 65,536 —
  the first hard wall you hit. Raise with `+Q`. The default process limit
  (262,144) binds later; raise with `+P`.
- **Kernel socket buffer memory**: ~4–8 KB per socket by default, outside BEAM
  RSS. At 500K connections that is 2–4 GB; at 1M, 4–8 GB. Tune `net.ipv4.tcp_rmem`
  and `tcp_wmem` downward for many-idle-connection workloads.
- **Client-side port exhaustion**: a *client* host can open ~64K outbound
  connections per destination IP:port pair. This does **not** cap a broker —
  a listening server is limited to ~64K connections *per distinct client IP*,
  since each connection is identified by the full 4-tuple. It matters when
  load-testing from a small number of source hosts, where you will hit the
  limit on the generator long before the broker.
- **Accept backlog**: raise `net.core.somaxconn` so reconnect bursts are not
  dropped at the listen queue.

### Beyond a single node

Past ~500K connections, consider clustering multiple BEAM nodes behind a load balancer. The constraints at this scale are fault isolation (a single node crash affects all connected devices) and system-level limits described above. A multi-node setup with 3–5 nodes provides both capacity and redundancy.

## Deployment Guidelines

### Single Node

See [Capacity Planning](#capacity-planning) above for per-instance figures and
the sizing method behind them. Note that QoS 2 carries higher overhead than the
numbers there imply, because of its four-step handshake.

### VM Tuning

For high connection counts, tune the BEAM scheduler:

```bash
# Use all available cores
elixir --erl "+S $(nproc)" -S mix run

# Increase process limit (default 262144)
elixir --erl "+P 1000000" -S mix run

# Increase port limit for socket handles
elixir --erl "+Q 200000" -S mix run
```

Or in `rel/vm.args`:

```text
+S 8:8
+P 1000000
+Q 200000
+stbt db
+sbwt very_long
```

### OS Tuning

```bash
# Increase file descriptor limit (each connection = 1 fd)
ulimit -n 200000

# Linux: increase socket buffer sizes
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 87380 16777216"

# Increase ephemeral port range
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
```

### Rate Limiting

For production deployments, enable rate limiting to protect against misbehaving clients and connection storms:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883,
  rate_limit: [
    max_connections: 100,    # per second
    max_messages: 1000       # per client per second
  ]
)
```

The rate limiter uses ETS with atomic `update_counter` for lock-free concurrent access. Counters reset automatically each interval window.

### Transport Selection

Both ThousandIsland and Ranch are battle-tested for high connection counts:

| Transport | Strengths | Notes |
|-----------|-----------|-------|
| ThousandIsland | Pure Elixir, simpler supervision | Recommended for new projects |
| Ranch | Mature Erlang acceptor pool, proven at scale | Used by Cowboy, RabbitMQ |

### Monitoring

Use the telemetry events (see [Telemetry guide](telemetry.md)) to track:

- **Connection rate**: `[:mqttx, :server, :client_connect, :stop]` counter
- **Message throughput**: `[:mqttx, :server, :publish]` counter
- **Publish latency**: `[:mqttx, :client, :publish, :stop]` duration histogram
- **Payload sizes**: `[:mqttx, :server, :publish]` payload_size distribution
- **Connection errors**: `[:mqttx, :client, :connect, :exception]` counter by reason

---

← Back to the [documentation index](../README.md#guides)
