# Performance & Scaling

MqttX is designed to handle 10,000 to 100,000+ concurrent device connections on a single BEAM node. This guide explains the architectural decisions and optimizations that make this possible.

## Architecture Overview

Each MQTT connection is a lightweight Erlang process (~2KB initial heap). The BEAM VM's preemptive scheduler distributes these processes across all available CPU cores. At 100k connections, memory overhead from the connection processes alone is roughly 200MB — well within reach of a modest server.

The key bottlenecks at scale are not the number of connections, but the **hot paths** that execute on every message:

| Hot Path | Frequency | Optimization |
|----------|-----------|--------------|
| Topic matching | Every PUBLISH | Trie-based router: O(L+K) vs O(N) |
| Packet encoding | Every outgoing packet | iodata output, zero binary copy |
| Buffer handling | Every TCP chunk | Empty-buffer fast path |
| Callback dispatch | Every incoming packet | Cached `function_exported?` |
| Flow control check | Every QoS 1/2 publish | Direct counter vs O(N) scan |
| Retained delivery | Every SUBSCRIBE | ETS lookup for exact topics |

## Topic Router

The router uses a **trie (prefix tree)** keyed by topic segments. Given a subscription to `sensors/+/temperature`, the trie looks like:

```
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

TCP delivers data in arbitrarily-sized chunks. In the common case, a complete MQTT packet arrives in a single TCP frame and the receive buffer is empty. The optimized path:

```elixir
buffer = case state.buffer do
  <<>> -> data          # Common case: no copy, just use the new data
  buf  -> buf <> data   # Partial packet pending: concat
end
```

The `<<>>` match is a constant-time check. When the buffer is empty (the majority case with typical MQTT packet sizes < TCP MSS), we skip binary concatenation entirely. The `rest` returned by `Codec.decode` is already a zero-copy sub-binary reference into the original data.

## Callback Dispatch

Elixir's `function_exported?/3` performs a module lookup on each call. For optional callbacks like `handle_info/2`, `handle_puback/3`, and `handle_mqtt_event/3`, this check runs on every incoming packet. MqttX computes these once at connection init:

```elixir
# Computed once in handle_connection/init:
handler_has_handle_info: function_exported?(handler, :handle_info, 2),
handler_has_handle_puback: function_exported?(handler, :handle_puback, 3)

# Then used as a simple boolean check per packet:
if state.handler_has_handle_puback do
  # ...
end
```

## Flow Control

MQTT 5.0's `receive_maximum` limits how many unacknowledged QoS 1/2 messages a client can have in flight. Instead of counting `{:tx, _}` entries in the `pending_acks` map on every publish (O(N) where N = pending messages), MqttX maintains a direct counter:

```elixir
defp can_send_qos_message?(state) do
  max_inflight = state.receive_maximum || 65535
  state.inflight_tx_count < max_inflight
end
```

The counter is incremented when adding a pending ack and decremented when receiving PUBACK/PUBCOMP or dropping expired messages.

## Retained Message Delivery

When a client subscribes, the server delivers matching retained messages from ETS. The optimized approach:

1. **Exact topic subscriptions** (no wildcards): Direct `ets.lookup/2` — O(1) per subscription.
2. **Wildcard subscriptions**: Table scan with pre-normalized topic lists. Topic filters are normalized once before the scan, and retained messages store a pre-computed normalized list alongside the string key, avoiding `String.split/2` in the inner loop.

For a server with 10,000 retained messages and a client subscribing to 5 exact topics, this reduces from 50,000 comparisons (5 filters x 10,000 messages) to 5 hash lookups.

## Capacity Planning

The primary bottleneck depends on your device activity pattern. For most IoT deployments, **RAM is the limiting factor, not CPU**.

### Per-device resource usage

Each connected device consumes approximately **~20KB of RAM** (process heap + connection state + socket). CPU usage depends entirely on message frequency.

### Device counts by workload

| Device activity | Per vCPU | Bottleneck |
|-----------------|----------|------------|
| Sleepy sensors (1 msg/min) | ~300K–500K | RAM |
| Normal IoT (1 msg/30s) | ~200K–500K | RAM |
| Chatty devices (1 msg/sec) | ~10K–15K | CPU |
| Real-time streaming (10 msg/sec) | ~1K–2K | CPU |

### Instance sizing

For typical IoT workloads (temperature sensors, ping/pong, periodic telemetry at ~1 msg/min):

| Instance | RAM | Devices | CPU usage |
|----------|-----|---------|-----------|
| 1 vCPU / 2GB | 2GB | ~80,000 | <5% |
| 2 vCPU / 4GB | 4GB | ~180,000 | <10% |
| 2 vCPU / 8GB | 8GB | ~350,000 | <10% |
| 4 vCPU / 16GB | 16GB | ~700,000 | <15% |

For active workloads (1 msg/sec per device), CPU becomes the constraint:

| Instance | Devices @ 1 msg/sec | Devices @ 10 msg/sec |
|----------|---------------------|----------------------|
| 1 vCPU | ~15,000 | ~1,500 |
| 2 vCPU | ~30,000 | ~3,000 |
| 4 vCPU | ~60,000 | ~6,000 |
| 8 vCPU | ~100,000 | ~10,000 |

CPU scaling is not perfectly linear due to ETS contention, scheduler rebalancing, and per-process GC pauses.

### Beyond a single node

Past ~500K connections, consider clustering multiple BEAM nodes behind a load balancer. The constraint is not CPU but process registry memory and fault isolation — a single node crash affects all connected devices. A multi-node setup with 3–5 nodes provides both capacity and redundancy.

## Deployment Guidelines

### Single Node

A single BEAM node with MqttX can handle:

| Metric | Conservative | Optimistic |
|--------|-------------|------------|
| Concurrent connections | 50,000 | 200,000 |
| Messages/second (QoS 0) | 100,000 | 500,000+ |
| Messages/second (QoS 1) | 50,000 | 200,000 |
| Memory per connection | ~2-5 KB | ~2-5 KB |
| Total memory (100k conns) | ~500 MB | ~500 MB |

These numbers depend on hardware, message sizes, and subscription patterns. QoS 2 has higher overhead due to the 4-step handshake.

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

```
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
| Ranch | Mature C-based acceptor, proven at scale | Used by Cowboy, RabbitMQ |

### Monitoring

Use the telemetry events (see [Telemetry guide](telemetry.md)) to track:

- **Connection rate**: `[:mqttx, :server, :client_connect, :stop]` counter
- **Message throughput**: `[:mqttx, :server, :publish]` counter
- **Publish latency**: `[:mqttx, :client, :publish, :stop]` duration histogram
- **Payload sizes**: `[:mqttx, :server, :publish]` payload_size distribution
- **Connection errors**: `[:mqttx, :client, :connect, :exception]` counter by reason
