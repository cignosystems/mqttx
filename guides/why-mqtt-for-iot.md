# Why MQTT for IoT

Background on protocol choice and on how MqttX compares to the other
Elixir/Erlang MQTT libraries. If you just want to use the library, start
with the [README](../README.md) or the
[Getting Started guide](getting-started.md).

## MQTT for cellular IoT

For IoT devices on cellular networks (LTE-M, NB-IoT), every byte matters. Data transmission costs money, drains batteries, and increases latency. MQTT combined with Protobuf dramatically outperforms WebSocket with JSON:

### Protocol Overhead Comparison

| Metric | WebSocket + JSON | MQTT + Protobuf | Savings |
|--------|------------------|-----------------|---------|
| Connection handshake | ~300-500 bytes | ~30-50 bytes | **90%** |
| Per-message overhead | 6-14 bytes | 2-4 bytes | **70%** |
| Keep-alive (ping) | ~6 bytes | 2 bytes | **67%** |

### Real-World Payload Example

Sending a sensor reading `{temperature: 25.5, humidity: 60, battery: 85}`:

| Format | Size | Notes |
|--------|------|-------|
| JSON | 52 bytes | `{"temperature":25.5,"humidity":60,"battery":85}` |
| Protobuf | 7 bytes | Binary: `0x08 0xCC 0x01 0x10 0x3C 0x18 0x55` |
| **Reduction** | **87%** | 7.4x smaller |

### Monthly Data Usage (1 device, 1 msg/min)

| Protocol | Payload | Monthly Data |
|----------|---------|--------------|
| WebSocket + JSON | 52 bytes | ~2.2 MB |
| MQTT + Protobuf | 7 bytes | ~0.3 MB |
| **Savings** | | **1.9 MB/device** |

For fleets of thousands of devices, this translates to significant cost savings on cellular data plans and extended battery life from reduced radio-on time.

### MQTT vs WebSocket (Same JSON Payload)

Even when using JSON for both protocols, MQTT still provides significant overhead savings:

| Metric | WebSocket + JSON | MQTT + JSON | Savings |
|--------|------------------|-------------|---------|
| Connection handshake | ~300-500 bytes | ~30-50 bytes | **90%** |
| Per-message overhead | 6-14 bytes | 2-4 bytes | **70%** |
| Keep-alive (ping) | ~6 bytes | 2 bytes | **67%** |
| 52-byte JSON message | 58-66 bytes total | 54-56 bytes total | **15-18%** |

**Key insight**: MQTT's binary protocol has lower framing overhead than WebSocket's text-based frames. For high-frequency IoT messages, this adds up significantly.

## Why MqttX?

Existing Elixir/Erlang MQTT libraries have limitations:

- **mqtt_packet_map**: Erlang-only codec, no server/client, slower encoding
- **Tortoise/Tortoise311**: Client-only, complex supervision, dated architecture
- **emqtt**: Erlang-focused, heavy dependencies

MqttX provides a **unified, pure Elixir solution** with:

- **2.9-4.2x faster encoding** than mqtt_packet_map for common packets
- Modern GenServer-based client with exponential backoff reconnection
- Transport-agnostic server that works with ThousandIsland or Ranch
- Clean, composable API designed for IoT and real-time applications
- Zero external dependencies for the core codec

The codec has been tested for interoperability with:

- **Zephyr RTOS** MQTT client (Nordic nRF9160, nRF52)
- **Eclipse Paho** clients (C, Python, JavaScript)
- **Mosquitto** broker
- Standard MQTT test suites

## Device-side configuration

### Connecting Nordic Thingy91 / nRF9160 (Zephyr MQTT)

Key Zephyr MQTT settings for MqttX compatibility:

```text
CONFIG_MQTT_KEEPALIVE=30        # Must be < cloud proxy idle timeout (e.g. Fly.io 60s)
CONFIG_MQTT_LIB_TLS=y           # TLS required for production
CONFIG_MQTT_CLEAN_SESSION=1     # Or use MQTT 5.0 session_expiry
```

Important notes:

- Zephyr's MQTT library supports MQTT 3.1.1 and 5.0
- For MQTT 5.0: `server_keep_alive` in CONNACK overrides the client's `CONFIG_MQTT_KEEPALIVE` — set it server-side for fleet control
- For cellular (LTE-M/NB-IoT): use keepalive ≤ 30s to survive cloud proxy idle timeouts (Fly.io, AWS IoT, Azure)
- Protobuf payloads recommended for cellular bandwidth savings

### Cloud Deployment with TLS Proxy

When deploying behind a TLS-terminating proxy (Fly.io, AWS NLB, Azure Front Door), ensure:

- Client keepalive < proxy idle timeout (usually 60s)
- Use `server_keep_alive` transport opt to enforce this server-side for all clients
- Fly.io: `internal_port` 8883, TLS terminated by Fly proxy

---

← Back to the [documentation index](../README.md#guides)
