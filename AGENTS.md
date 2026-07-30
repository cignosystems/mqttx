# AGENTS.md

Guidance for AI coding assistants integrating **MqttX** into a project.
Read this before suggesting code that uses this library — it captures the
mental model and the mistakes agents most often make.

> Modifying MqttX itself? See `CONTRIBUTING.md` for repo layout, test commands,
> and deferred work.

## What MqttX is

A single hex package (`{:mqttx, "~> 0.11.0"}`) that ships **three independent
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
| Any client transport behind an HTTP `CONNECT` proxy | nothing extra — pass `proxy: [host:, port:, auth:]` |
| WebSocket client (`ws` / `wss`) | nothing extra (RFC 6455 client is built-in) |
| TCP server | `{:thousand_island, "~> 1.4"}` (preferred) or `{:ranch, "~> 2.2"}` |
| WebSocket server | `{:bandit, "~> 1.6"} + {:websock_adapter, "~> 0.5 or ~> 0.6"}` |

If `MqttX.Transport.ThousandIsland` (or `Ranch`, or `Bandit`) fails at server
startup with an undefined-module / undefined-function error, the
corresponding optional dep is missing from `mix.exs` — that's the single most
common setup mistake.

## Mental model — client side

```text
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
- `MqttX.Client.connect/1` is **asynchronous**: it returns as soon as the
  process starts, *before* CONNACK. A `subscribe`/`publish` issued immediately
  after it returns gets `{:error, :not_connected}`. Either act in the
  `:connected` handler event, or pass `await_connect: true` to have
  `connect/1` block until the first attempt resolves (returning
  `{:error, reason}` if it failed). The async default exists so a client can
  start before the broker is reachable and retry with backoff.
- `subscribe/3` is synchronous and **waits for SUBACK** before returning
  `{:ok, granted_qos_list}`. `publish/4` returns `:ok` as soon as the packet
  is written to the socket (it does not wait for PUBACK at QoS 1/2 — those
  acks are tracked in the background and surfaced via the handler module).
- If the connection has dropped (and not yet reconnected), `subscribe`,
  `publish`, and `unsubscribe` return `{:error, :not_connected}` immediately —
  they do not queue.
- **Resubscription is automatic** (since 0.11.0): granted subscriptions are
  tracked and replayed after any reconnect whose CONNACK reports
  `session_present: false`. You do not need to resubscribe in the
  `:connected` handler.
- The handler module implements **`handle_mqtt_event/3`**, which receives:
  - `(:connected, %{properties: props, session_present: bool}, state)` — after CONNACK success
  - `(:disconnected, reason, state)` — `reason` is `:closed`, `:pingresp_timeout`, `{:error, posix}`, `{:protocol_error, reason}`, `{:server_disconnect, code, props}`, or `{:connack_error, code, info}`
  - `(:message, {topic, payload, full_packet}, state)` — for each PUBLISH
  - `(:publish_error, {topic, packet_id, reason_code}, state)` — the broker
    rejected one of your QoS 1/2 publishes (e.g. `0x87` not authorized)

  Give the handler a catch-all clause (`handle_mqtt_event(_e, _d, state)`) so
  new event types don't raise. A raising handler is caught and logged rather
  than killing the connection, but its state update is lost.

`topic` arrives as a **list of segments** (`["sensors", "room1", "temp"]`),
not the original string — use `Enum.join(topic, "/")` if you need to round-trip.

## Mental model — broker side

`use MqttX.Server` defines a behaviour with one callback per MQTT verb:

```text
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

  def handle_mqtt_event(:publish_error, {_topic, _packet_id, reason_code}, state) do
    Logger.warning("broker rejected publish: #{inspect(reason_code)}")
    state
  end

  # Catch-all so new event types don't raise
  def handle_mqtt_event(_event, _data, state), do: state
end

{:ok, c} = MqttX.Client.connect(
  host: "broker.example.com",
  client_id: "my-app-#{node()}",
  handler: MyApp.MqttHandler,
  handler_state: %{},
  # connect/1 is async by default; block so the subscribe below succeeds
  await_connect: true
)

{:ok, _granted} = MqttX.Client.subscribe(c, "sensors/#", qos: 1)
```

### Module-based client (`use MqttX`)

Equivalent to the handler-module pattern above, but callbacks, connection and
supervision live in one module. Callbacks run in the module's **own process**,
so publishing from inside one is safe (a `GenServer.call` back into the
connection would otherwise deadlock):

```elixir
defmodule MyApp.Sensors do
  use MqttX

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_connected(_info, state) do
    subscribe("sensors/#", qos: 1)
    {:ok, state}
  end

  @impl true
  def handle_message(topic, payload, _packet, state) do
    publish("ack/" <> Enum.join(topic, "/"), payload, qos: 1)
    {:ok, state}
  end
end

children = [{MyApp.Sensors, host: "broker.example.com", client_id: "sensors-1"}]
```

Callbacks: `init/1`, `handle_message/4`, `handle_connected/2`,
`handle_disconnected/2`, `handle_publish_error/4`, `handle_info/2` — all
defaulted, each returning `{:ok, state}` or `{:stop, reason, state}`. Note
these are **not** the same as `handle_mqtt_event/3`; a module using
`use MqttX` implements these instead.

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

### MQTT 5.0 persistent sessions (resume QoS 1/2 across reconnects)

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

- **Assuming TLS is unverified.** Since 0.11.0 `:ssl`/`:wss` verify the
  broker certificate by default (OS trust store + SNI + hostname check).
  Pointing at a self-signed/expired dev broker now *fails* — supply the CA
  with `ssl_opts: [cacertfile: ...]`, or opt out deliberately with
  `ssl_opts: [verify: :verify_none]`. Don't "fix" a verification failure by
  reaching for `verify_none` in production code.
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
- **Assuming MqttX's own broker keeps sessions.** `MqttX.Server` does not
  queue messages for disconnected clients and always answers
  `session_present: false` — `clean_session: false` buys you nothing against
  *this* broker (it works as expected against EMQX, Mosquitto, etc.). Model
  durable state in your handler with Phoenix.PubSub or a database.
- **Treating `MqttX.Server.Router` as a public pubsub.** It is the broker's
  internal subscription index. To send messages between processes, use
  Phoenix.PubSub or `:pg`, then bridge via the broker callback.
- **Setting `keepalive` higher than the cloud-proxy idle timeout.** Fly.io,
  AWS NLB, Azure Front Door all idle TCP at ~60s. Use ≤ 30s for cellular IoT
  or set `server_keep_alive: 30` in `transport_opts` to enforce it server-side
  for v5 clients.
- **Assuming retained = "all past messages".** Retain stores the **last**
  message per topic only — it's a "current state" mechanism, not a history.
- **Ignoring CONNACK reason codes.** By default `connect/1` returns
  `{:ok, pid}` before the handshake completes, so a rejection arrives at the
  handler as
  `(:disconnected, {:connack_error, reason_code, %{server_reference: ref_or_nil}})`
  — handle it there (e.g. `0x84` unsupported version, `0x86` bad credentials,
  `0x9C` use the server reference to redirect). With `await_connect: true`
  the same tuple is returned from `connect/1` instead. Non-retryable codes
  stop the client rather than reconnecting forever.

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
- **Recent behaviour changes:** `CHANGELOG.md` — the `[0.11.0]` entry is the
  important one: secure-by-default TLS, packet/idle limits, automatic
  resubscription, and `use MqttX`. The `[0.10.0]` entry documents the spec
  sweep that tightened many edge cases older internet examples don't reflect
- **MQTT spec:** OASIS [3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/) /
  [5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/) — section references in
  this codebase (e.g. `§3.3.1.2`) point here
