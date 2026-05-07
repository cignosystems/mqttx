# AGENTS.md

Guidance for AI coding assistants integrating **MqttX** into a project.
Read this before suggesting code that uses this library — it captures the
mental model and the mistakes agents most often make.

> Modifying MqttX itself? See `CONTRIBUTING.md` for repo layout, test commands,
> and deferred work.

## What MqttX is

A single hex package (`{:mqttx, "~> 0.10"}`) that ships **three independent
pieces** — choose only what you need:

| Piece | Module | Use when |
|-------|--------|----------|
| **Wire codec** | `MqttX.Packet.Codec` | You have your own transport and just need encode/decode |
| **Client** | `MqttX.Client` | Your app connects to an MQTT broker (AWS IoT, EMQX, HiveMQ, Mosquitto, …) |
| **Broker** | `MqttX.Server` | You are *running* an MQTT broker (e.g. an IoT backend that owns its devices) |

Most apps want only the **client**. Build a broker only when you need to own
the message routing — for talking to a third-party broker, the client is
sufficient on its own.

## Picking a transport

The codec is dep-free; transports are optional packages:

| Transport | Add to deps |
|-----------|-------------|
| TCP / TLS client (`tcp` / `ssl`) | nothing extra |
| WebSocket client (`ws` / `wss`) | nothing extra (RFC 6455 client is built-in) |
| TCP server | `{:thousand_island, "~> 1.4"}` (preferred) or `{:ranch, "~> 2.2"}` |
| WebSocket server | `{:bandit, "~> 1.6"} + {:websock_adapter, "~> 0.5"}` |

If `MqttX.Transport.ThousandIsland` (or `Ranch`, or `Bandit`) fails at server
startup with an undefined-module / undefined-function error, the
corresponding optional dep is missing from `mix.exs` — that's the single most
common setup mistake.

## Mental model — client side

```
your code  ──MqttX.Client.subscribe──▶  broker
your code  ──MqttX.Client.publish───▶  broker
                                          │
              MqttX.Client ◀─PUBLISH──────┘
                   │
                   ▼
       handler_module.handle_mqtt_event(:message, {topic, payload, packet}, state)
```

- The client is a **GenServer**. You don't poll it — it pushes events to a
  handler module.
- `MqttX.Client.connect/1` blocks until CONNACK arrives, so once it returns
  `{:ok, pid}` the session is live and you can immediately subscribe/publish.
- `subscribe/3` is synchronous and **waits for SUBACK** before returning
  `{:ok, granted_qos_list}`. `publish/4` returns `:ok` as soon as the packet
  is written to the socket (it does not wait for PUBACK at QoS 1/2 — those
  acks are tracked in the background and surfaced via the handler module).
- If the connection has dropped (and not yet reconnected), `subscribe`,
  `publish`, and `unsubscribe` return `{:error, :not_connected}` immediately —
  they do not queue.
- The handler module implements **`handle_mqtt_event/3`**, which receives:
  - `(:connected, %{properties: props, session_present: bool}, state)` — after CONNACK success
  - `(:disconnected, reason, state)` — `reason` is `:closed`, `:pingresp_timeout`, `{:error, posix}`, or `{:server_disconnect, code, props}`
  - `(:message, {topic, payload, full_packet}, state)` — for each PUBLISH

`topic` arrives as a **list of segments** (`["sensors", "room1", "temp"]`),
not the original string — use `Enum.join(topic, "/")` if you need to round-trip.

## Mental model — broker side

`use MqttX.Server` defines a behaviour with one callback per MQTT verb:

```
device  ──CONNECT──▶  handle_connect(client_id, creds, info, state)
device  ──SUBSCRIBE─▶  handle_subscribe(topics, state)         → grant per-topic QoS
device  ──PUBLISH──▶  handle_publish(topic, payload, opts, state)
device  ──DISCONNECT▶  handle_disconnect(reason, state)

your app ──send(broker_pid, msg)─▶ handle_info(msg, state)
                                       └─▶ {:publish, topic, payload, state}  (fan out to device)
```

Servers are *per-connection* state machines — `state` is one device's state.
For app-wide state (subscriber registry, message bus), use Phoenix.PubSub or
`:pg` from inside the callbacks.

## Idiomatic patterns

### Receive messages on the client

```elixir
defmodule MyApp.MqttHandler do
  def handle_mqtt_event(:connected, _info, state), do: state
  def handle_mqtt_event(:disconnected, _reason, state), do: state

  def handle_mqtt_event(:message, {topic, payload, _packet}, state) do
    Logger.info("got #{payload} on #{Enum.join(topic, "/")}")
    state
  end
end

{:ok, c} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "my-app-#{node()}",
  handler: MyApp.MqttHandler,
  handler_state: %{}
)

{:ok, _granted} = MqttX.Client.subscribe(c, "sensors/#", qos: 1)
```

### Bridge MQTT broker ↔ Phoenix.PubSub (fan-out)

```elixir
defmodule MyBroker do
  use MqttX.Server

  def init(_), do: %{}

  def handle_connect(client_id, _creds, _info, state) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "downlink:#{client_id}")
    {:ok, Map.put(state, :client_id, client_id)}
  end

  def handle_publish(topic, payload, _opts, state) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "uplink", {state.client_id, topic, payload})
    {:ok, state}
  end

  def handle_info({:downlink, topic, payload}, state) do
    {:publish, topic, payload, %{qos: 1, retain: false}, state}
  end

  def handle_subscribe(topics, s), do: {:ok, Enum.map(topics, & &1.qos), s}
  def handle_disconnect(_r, _s), do: :ok
end

# elsewhere in your app:
Phoenix.PubSub.broadcast(MyApp.PubSub, "downlink:device-123",
  {:downlink, "device-123/cmd", "reboot"})
```

### MQTT 5 persistent sessions (resume QoS 1/2 across reconnects)

```elixir
MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "stable-id-not-uuid",                    # MUST be stable across reconnects
  protocol_version: 5,                                # required for properties
  clean_session: false,
  connect_properties: %{session_expiry_interval: 3600},
  session_store: MqttX.Session.ETSStore               # client-side persistence
)
```

### Custom auth (reject CONNECT)

```elixir
def handle_connect(client_id, %{username: u, password: p}, _info, state) do
  case MyApp.Auth.verify(u, p) do
    {:ok, _} -> {:ok, state}
    :error   -> {:error, 0x86, state}    # 0x86 = Bad User Name or Password
  end
end
```

Reason codes worth knowing: `0x80` Unspecified, `0x86` Bad credentials,
`0x87` Not authorized, `0x95` Packet too large, `0x97` Quota exceeded.
Full list in MQTT 5.0 §2.4.

## Common mistakes (do not do these)

- **Wildcards in PUBLISH.** `+` and `#` are subscribe-only — publishing them
  is a Protocol Error and the broker will disconnect. Validate with
  `MqttX.Topic.validate_publish/1` for any topic that mixes user input.
- **Using `handle_publish/4` on the client.** That's a *server* callback. The
  client receives PUBLISHes via `handle_mqtt_event(:message, …)`. They are
  *not* the same callback — agents confuse this constantly.
- **`clean_session: false` without `:session_store`.** The flag tells the
  *broker* to keep state. For the *client* to remember in-flight QoS 1/2
  across reconnects, also pass `:session_store`.
- **Random `client_id` per connect.** Sessions, retained messages, and shared
  subscriptions are all keyed by `client_id`. `UUID.uuid4()` per connect
  silently breaks all three.
- **Picking QoS 2 by default.** QoS 2 is a 4-packet handshake (PUBLISH →
  PUBREC → PUBREL → PUBCOMP) — use it only when *duplicate delivery would
  cause real harm* (financial transactions). For telemetry use QoS 0; for
  commands use QoS 1.
- **Expecting `#` to match `$SYS/...`.** Per MQTT §4.7.2, `$`-prefixed topics
  require explicit subscription. `subscribe(c, "#")` does **not** receive
  `$SYS/broker/uptime`.
- **Treating `MqttX.Server.Router` as a public pubsub.** It is the broker's
  internal subscription index. To send messages between processes, use
  Phoenix.PubSub or `:pg`, then bridge via the broker callback.
- **Setting `keepalive` higher than the cloud-proxy idle timeout.** Fly.io,
  AWS NLB, Azure Front Door all idle TCP at ~60s. Use ≤ 30s for cellular IoT
  or set `server_keep_alive: 30` in `transport_opts` to enforce it server-side
  for v5 clients.
- **Assuming retained = "all past messages".** Retain stores the **last**
  message per topic only — it's a "current state" mechanism, not a history.
- **Ignoring CONNACK reason codes.** `MqttX.Client.connect/1` returns
  `{:ok, pid}` only on success; on broker rejection it returns
  `{:error, {:connack_error, reason_code, %{server_reference: ref_or_nil}}}`
  (e.g. `0x84` for unsupported version, `0x86` for bad credentials, `0x9C` to
  use the included server reference for redirect).

## Decision helpers

- **Topic structure:** prefer hierarchy that matches your subscription
  patterns. `tenant/{id}/device/{id}/telemetry/{metric}` lets `tenant/+/device/+/telemetry/#`
  fan out cleanly. Avoid encoding multiple dimensions into one segment.
- **Payload format:** Protobuf for cellular IoT (5-10× smaller than JSON);
  JSON for backend interop where payload size doesn't dominate.
- **`max_inflight` on the client:** default 100. Raise only if your broker
  advertises a high `receive_maximum` *and* you're seeing throughput limits;
  otherwise increasing it just delays backpressure.
- **Shared subscriptions** (`$share/group/topic`): use to load-balance
  consumers, not to broadcast. Each message goes to exactly one subscriber
  in the group. Subscribing to the same topic from N clients without `$share`
  delivers N copies.

## Where to find authoritative answers

- **Public API:** [hexdocs.pm/mqttx](https://hexdocs.pm/mqttx) — `@doc`
  strings on every public function
- **Worked examples:** `README.md` ("Common Patterns") and the integration
  tests at `test/mqttx/integration_test.exs` and
  `test/mqttx/interop_emqx_test.exs`
- **Recent behavior changes:** `CHANGELOG.md` — the `[0.10.0]` entry
  documents the v0.10.0 spec sweep, which tightened many edge cases that older
  examples on the internet may not reflect
- **MQTT spec:** OASIS [3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/) /
  [5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/) — section references in
  this codebase (e.g. `§3.3.1.2`) point here
