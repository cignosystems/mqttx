# Server Guide

`MqttX.Server` is a behaviour for building MQTT brokers. You implement handler callbacks; MqttX handles the protocol, transport, and routing.

## Handler Callbacks

```elixir
defmodule MyApp.MqttHandler do
  use MqttX.Server

  @impl true
  def init(_opts), do: %{subscriptions: %{}}

  @impl true
  def handle_connect(client_id, credentials, state) do
    IO.puts("Client connected: #{client_id}")
    {:ok, state}
  end

  @impl true
  def handle_publish(topic, payload, opts, state) do
    IO.puts("Received on #{inspect(topic)}: #{payload}")
    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state) do
    qos_list = Enum.map(topics, fn t -> t.qos end)
    {:ok, qos_list, state}
  end

  @impl true
  def handle_unsubscribe(_topics, state), do: {:ok, state}

  @impl true
  def handle_disconnect(reason, _state) do
    IO.puts("Client disconnected: #{inspect(reason)}")
    :ok
  end

  @impl true
  def handle_info(message, state) do
    # Handle custom messages (e.g., Phoenix.PubSub broadcasts)
    {:ok, state}
  end
end
```

### Callback Summary

| Callback | Return |
|----------|--------|
| `init(opts)` | `state` |
| `handle_connect(client_id, credentials, connect_info, state)` | *(optional)* Same as the 3-arity form plus `%{protocol_version:, keep_alive:, authentication_method:, session_present:, subscriptions:}`; takes precedence when defined |
| `handle_connect(client_id, credentials, state)` | `{:ok, state}` or `{:error, reason_code, state}` |
| `handle_publish(topic, payload, opts, state)` | `{:ok, state}`, `{:error, reason, state}` (refused but still acknowledged — QoS 1 gets a PUBACK with a refusal code, e.g. `0x87` for `:unauthorized`), `{:disconnect, reason_code, state}` |
| `handle_subscribe(topics, state)` | `{:ok, granted_qos_list, state}`, `{:disconnect, reason_code, state}` |
| `handle_unsubscribe(topics, state)` | `{:ok, state}`, `{:disconnect, reason_code, state}` |
| `handle_disconnect(reason, state)` | `:ok` |
| `handle_info(message, state)` | `{:ok, state}`, `{:publish, ...}`, `{:disconnect, reason_code, state}`, or `{:stop, reason, state}` |
| `handle_puback(packet_id, state)` | `{:ok, state}` *(optional)* — a QoS 1 PUBLISH you sent was acknowledged |
| `handle_auth(method, data, state)` | `{:ok, state}`, `{:ok, data, state}`, `{:continue, data, state}`, or `{:error, reason_code, state}` *(optional, MQTT 5.0 enhanced auth — see [Enhanced Authentication](#enhanced-authentication))* |
| `handle_session_expired(client_id, state)` | `:ok` (optional) |

Use `handle_info/2` with `{:publish, topic, payload, state}` to push messages to connected clients from external events (e.g., PubSub). When the topic matches one of the client's subscriptions, the delivery honors the subscription's options: QoS is capped at the granted QoS, `retain` is forwarded only if the subscription set Retain As Published, and subscription identifiers are attached. Pass `publisher: originating_client_id` in the opts to honor `no_local` subscriptions. A publish matching no subscription is sent exactly as given. To fan a message out to *every* subscribed session, connected or not, use `MqttX.Server.deliver/3` — see [Delivering Messages](#delivering-messages).

Any callback that returns `{:disconnect, reason_code, state}` or `{:disconnect, reason_code, properties, state}` will send an MQTT 5.0 DISCONNECT packet to the client and close the connection.

## Delivering Messages

A publish arriving at `handle_publish/4` is yours to authorize; the fan-out
is the broker's. `MqttX.Server.deliver/3` matches a topic against the
subscriptions of every session on the listener — connected or not — and
sends, with each subscription's options applied: QoS capped at the granted
QoS, `retain` kept only for Retain As Published subscriptions, Subscription
Identifiers attached, one member per shared subscription (a connected one
when there is one), and `no_local` honored when you name the `:publisher`.

```elixir
@impl true
def handle_publish(topic, payload, opts, state) do
  if MyApp.ACL.may_publish?(state.client_id, topic) do
    MqttX.Server.deliver(topic, payload, Map.put(opts, :publisher, state.client_id))
    {:ok, state}
  else
    {:error, :unauthorized, state}
  end
end
```

From outside a callback — a controller, a job — address the listener by the
`:name` it was started with (or its port number):

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [], name: MyApp.Broker, port: 1883)

MqttX.Server.deliver(MyApp.Broker, "devices/42/cmd", "reboot", %{qos: 1})
```

A session that is not connected but has not expired gets QoS 1 and 2
messages queued — bounded by the `:max_outbound_queue` transport option, with
any Message Expiry Interval still counting down — and receives them in order
when it reconnects. QoS 0 messages are not queued for an absent client.
A connected session that will outlive its connection is served through the
same queue, so a message cannot be lost if the connection drops at the wrong
moment; a session that ends with its connection is sent to directly, which
keeps the usual clean-session fan-out at the push path's speed. `deliver`
returns `{:ok, n}`, the number of sessions the message went to.
Unlike an inbound PUBLISH, `retain: true` here does not write the retained
store; it only marks the delivery for Retain As Published subscribers.

`{:publish, ...}` returns from `handle_info/2` remain the way to push to the
one client a connection serves, for brokers that route through their own
PubSub.

## Transport Adapters

### ThousandIsland (Recommended)

```elixir
# mix.exs: {:thousand_island, "~> 1.4"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

### Ranch

```elixir
# mix.exs: {:ranch, "~> 2.2"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.Ranch,
  port: 1883,
  # :ranch_tcp (default) or :ranch_ssl. Named `:transport` before v0.11.0,
  # which collided with the adapter selector above.
  ranch_transport: :ranch_tcp
)
```

### WebSocket

```elixir
# mix.exs: {:bandit, "~> 1.6"}, {:websock_adapter, "~> 0.5 or ~> 0.6"}

{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8083
)

# wss:// — the same TLS options ThousandIsland's SSL transport takes
{:ok, _pid} = MqttX.Server.start_link(
  MyApp.MqttHandler,
  [],
  transport: MqttX.Transport.WebSocket,
  port: 8084,
  scheme: :https,
  transport_options: [certfile: "/etc/mqttx/cert.pem", keyfile: "/etc/mqttx/key.pem"]
)
```

All transports support plain TCP and TLS. See `MqttX.Transport` for implementing custom adapters.

## Topic Routing

The built-in router uses a trie data structure for efficient topic matching — O(L+K) where L is the topic depth and K is matching subscriptions. It supports MQTT wildcard subscriptions (`+` single-level, `#` multi-level):

```elixir
alias MqttX.Server.Router

router = Router.new()
router = Router.subscribe(router, "sensors/+/temp", client_ref, qos: 1)
router = Router.subscribe(router, "alerts/#", client_ref, qos: 0)

matches = Router.match(router, "sensors/room1/temp")
# => [{client_ref, %{qos: 1}}]
```

### Shared Subscriptions

Distribute messages across a group of subscribers with round-robin load balancing:

```elixir
router = Router.subscribe(router, "$share/workers/jobs/#", worker1, qos: 1)
router = Router.subscribe(router, "$share/workers/jobs/#", worker2, qos: 1)

# Messages to "jobs/process" alternate between worker1 and worker2
{matches, router} = Router.match_and_advance(router, "jobs/process")
```

## Rate Limiting

MqttX supports per-client connection and message rate limiting. Configure it via the `:rate_limit` option:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883,
  rate_limit: [
    max_connections: 100,    # new connections per second
    max_messages: 1000,      # messages per client per second
    interval: 1000           # window size in ms (default)
  ]
)
```

| Option | Description | Default |
|--------|-------------|---------|
| `:max_connections` | Max new connections per interval | unlimited |
| `:max_messages` | Max messages per client per interval | unlimited |
| `:interval` | Counter reset interval in ms | `1000` |

When a client exceeds the message rate limit:
- **QoS 0**: Messages are silently dropped
- **QoS 1 / 2**: PUBACK / PUBREC is sent with reason code `0x97` (Quota
  exceeded) and the message is not delivered; the session stays up. (`0x96`
  Message rate too high exists only for DISCONNECT, §2.4.)

When the connection rate limit is exceeded, new connections are immediately closed.

Rate limiting uses ETS with atomic `update_counter` operations, making it lock-free and safe for concurrent access from multiple transport handler processes.

## Retained Messages

The server automatically stores retained messages in ETS and delivers them to new subscribers. Publish with an empty payload to clear a retained message.

## Keepalive Timeout

The server enforces MQTT keepalive as defined in the spec: if no packet is received from a client within 1.5x the `keep_alive` interval (set in the CONNECT packet), the server disconnects the client and publishes any will message.

The keepalive timer resets on every received packet (not just PINGREQ). Clients that set `keep_alive: 0` are exempt from keepalive enforcement — but not from the idle ceiling below.

When a keepalive timeout fires, your `handle_disconnect/2` callback receives `:keepalive_timeout` as the reason.

### Capping the Keep Alive (MQTT 5.0)

`server_keep_alive: 30` in `transport_opts` lowers a Keep Alive above 30 s —
or a client's 0, meaning none — to 30: the CONNACK carries Server Keep Alive
(§3.2.2.3.14) and the client must use it (MQTT-3.1.2-21). A client asking
for less keeps its own value. Use it behind a cloud proxy whose idle timeout
would otherwise cut silent connections. A 3.1.1 client cannot be told, so it
keeps what it asked for.

### Idle ceiling

Because MQTT keepalive does not apply when a client connects with
`keep_alive: 0`, the server additionally closes any socket idle for longer
than `:max_idle_timeout` (default 15 minutes), regardless of the negotiated
Keep Alive. The timer resets on any inbound data, so it never interferes with
a client that is honoring its keepalive. `handle_disconnect/2` receives
`:idle_timeout`.

```elixir
transport_opts: %{max_idle_timeout: 900_000}   # :infinity disables
```

A separate `:connect_timeout` (default 10 s) closes sockets that never
complete CONNECT.

## Will Messages

Will messages from the CONNECT packet are published automatically whenever
the connection ends without the client having sent `DISCONNECT 0x00`
(§3.1.2.5): a socket drop, a keep-alive or idle timeout, a protocol error,
a handler's `{:disconnect, ...}` return, `MqttX.Server.disconnect/3`, and a
session takeover by a new connection with the same client id. Only the
client's own normal DISCONNECT discards the Will (a `DISCONNECT 0x04` asks
for it to be published). The Will's topic and payload are offered to
`handle_publish/4` like any other message, so your authorization applies.

### Will Delay Interval (MQTT 5.0)

MQTT 5.0 clients can set `will_delay_interval` in the will properties to delay publication of the will message:

- `will_delay_interval: 0` (or MQTT 3.1.1) — will published immediately (default)
- `will_delay_interval: N` — will published N seconds after ungraceful disconnect

This allows a grace period for clients to reconnect before their "last will"
is broadcast: a new connection for the same client id within the delay
cancels the pending Will (§3.1.3.2.2), as does a session takeover. The delay
needs a non-zero Session Expiry Interval — with the default of 0 the session
ends at disconnect and the Will is published at once.

## Session State

The broker keeps each client's Session State (MQTT §4.1) in ETS, per
listener, so it outlives the connection:

- the subscriptions, with their options and Subscription Identifiers
- QoS 1/2 messages in flight in either direction
- messages `MqttX.Server.deliver/3` queued while the client was away
- when the session ends

A client that connects with Clean Start 0 and a non-zero Session Expiry
Interval — or, for MQTT 3.1.1, CleanSession 0 — resumes its session on
reconnect: the CONNACK says `session_present: true`, its subscriptions are
live again without a new SUBSCRIBE, unacknowledged QoS 1/2 PUBLISHes are
re-sent with DUP set (the one case §4.4 allows), a PUBREL whose PUBCOMP never
came goes out again, an inbound QoS 2 message still waiting for its PUBREL
is completed, and the queue drains in order. Clean Start 1 discards whatever
was stored. `handle_connect/4`'s `connect_info` carries `session_present` and
the `subscriptions` coming back, for handlers that re-establish their own
routing on reconnect.

A connection taking over a client id (§3.1.4) inherits the session: the old
connection is told to let go and the new one resumes from the store.

The state lives in memory on the node that holds the connection. It survives
the connection process and a listener restart, not a restart of the BEAM; a
client reconnecting to another node starts fresh.

## Clustering

Run the same handler on several nodes of an Erlang cluster and give the
listener the same `:name` on each:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [], name: MyApp.Broker, port: 1883)
```

Listeners sharing a name form one broker across the connected nodes (via
`:pg`; connect the nodes with libcluster or `Node.connect/1`). Nothing else
is configured, and a device may connect to any node:

- **Delivery.** `MqttX.Server.deliver/3,4` reaches every node with a
  matching subscription, so a device connected to node A receives what was
  published on node B, and a persistent session that is away gets it
  queued on the node that holds it. Each node tells the others which
  filters its sessions subscribe to, and a message goes only to the nodes
  with a matching one (to every node until that node's filters have
  arrived). A new subscription reaches the other nodes within one message
  between them; a message published elsewhere in that moment can miss it.
  `deliver` returns the count for the local node only.
- **Sessions follow the client.** A CONNECT on one node reaches the others:
  a connection still open there for the same client id is taken over
  (DISCONNECT 0x8E, §3.1.4), its pending Will Delay and Session Expiry are
  cancelled, and its stored session moves to the new node — subscriptions,
  in-flight QoS 1/2 and queued messages, with Message Expiry still counting.
  Clean Start 1 discards it on every node instead. `handle_connect/4` sees
  the session that would be resumed wherever it is (`session_present`,
  `subscriptions`).
- **Retained messages** are replicated to every node; a node that joins
  later receives the others' retained messages. Two nodes writing the same
  topic at once settle on the later write. A clear (empty retained payload)
  is remembered for an hour, so a node that missed it — cut off from the
  others at the time — cannot bring the cleared message back when it
  reconnects.
- **Shared subscriptions** deliver each message once across the cluster:
  members are known to every node, and the publishing node picks one member
  wherever it is connected (rotating, connected members first). The node
  holding a member it picked answers whether it took the message; when its
  client is offline, its session is gone, or that node leaves before
  answering, the next member is picked — connected members first, an
  offline member's session only when none is left. A node that leaves after
  taking a message but before answering can cause it to be delivered twice
  (at least once, as §4.8.2 allows when a member's connection is lost).

A CONNECT waits for the other nodes' answer, at most five seconds; a node
that answers later keeps nothing (its session is discarded, not moved).
Messages published while a session moves reach it once each and in each
publisher's order (§4.6): the node it left forwards what it matches for the
client, the new node drops the copies it already has, and until everything
any node sent the old node before the hand-over has been forwarded — a
round trip through every node, milliseconds — the new node holds back what
it matches itself. If that takes longer than five seconds (a node not
answering), the held messages are delivered anyway, and order is no longer
guaranteed for them.

A network split between nodes leaves each side working on its own: a
client may connect on both, and each side keeps its retained writes. When
the nodes reach each other again, a client with a session on both sides
keeps the one it began last — the other side disconnects its connection
there (0x8E) and discards that copy, with what was queued in it — and the
retained messages settle on the later write of each topic.

A session lives on one node at a time, so a node that goes down takes its
sessions with it — unless the listener has a durable backend the other
nodes reach too (next section). `docs/design/clustering.md` in the
repository has the design notes.

### Durable sessions

Sessions live in ETS and end with the node. To keep them across a restart,
give the listener a `MqttX.Server.SessionBackend`:

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  name: MyApp.Broker,
  port: 1883,
  session_backend: {MqttX.Server.SessionBackend.DETS, path: "/var/lib/broker/sessions.dets"},
  session_flush_interval: 1_000
)
```

ETS stays the working copy; changed sessions are saved behind it every
`:session_flush_interval` milliseconds (default 1000), so a crash loses at
most that much. When the listener starts it loads back the sessions this
node saved, and a session saved by a node that is gone is loaded when its
client connects. `MqttX.Server.SessionBackend.DETS` is a local file — enough
for one node's restarts. `MqttX.Server.SessionBackend.Replicated` keeps every
saved session on every node of the cluster, in memory, so a client whose
node goes down resumes its session on another (at the cost of every node
holding every persistent session); it does not survive a restart of the
whole cluster. For both, put the sessions in a database.

#### A database backend

The behaviour has five callbacks, and a record is an opaque term, so a
table with the listener, the client id and the record as a binary is
enough. With Ecto and Postgres:

```elixir
# priv/repo/migrations/20260101000000_create_mqtt_sessions.exs
defmodule MyApp.Repo.Migrations.CreateMqttSessions do
  use Ecto.Migration

  def change do
    create table(:mqtt_sessions, primary_key: false) do
      # Client ids are UTF-8 strings of up to 65 535 bytes (§3.1.3.1)
      add :listener, :text, primary_key: true
      add :client_id, :text, primary_key: true
      # The node that saved the record; `expires_at` is null while connected
      add :node, :text, null: false
      add :expires_at, :utc_datetime
      add :record, :binary, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create index(:mqtt_sessions, [:node])
    create index(:mqtt_sessions, [:expires_at])
  end
end
```

```elixir
defmodule MyApp.MqttSessions do
  @moduledoc """
  The broker's sessions in Postgres, through Ecto. Every node reaches the
  same table, so a session survives the loss of its node and a restart of
  the whole cluster.
  """

  @behaviour MqttX.Server.SessionBackend

  import Ecto.Query, only: [from: 2]
  alias MyApp.Repo

  @table "mqtt_sessions"

  # One table serves every listener; the listener's name is part of the key
  @impl true
  def init(listener, _opts), do: {:ok, inspect(listener)}

  @impl true
  def save(listener, client_id, record) do
    row = %{
      listener: listener,
      client_id: client_id,
      node: to_string(Map.get(record, :node, node())),
      expires_at: expires_at(record),
      record: :erlang.term_to_binary(record),
      updated_at: DateTime.utc_now(:second)
    }

    {1, _} =
      Repo.insert_all(@table, [row],
        on_conflict: {:replace, [:node, :expires_at, :record, :updated_at]},
        conflict_target: [:listener, :client_id]
      )

    :ok
  end

  @impl true
  def load(listener, client_id) do
    query =
      from(s in @table,
        where: s.listener == ^listener and s.client_id == ^client_id,
        select: s.record
      )

    case Repo.one(query) do
      nil -> :none
      binary -> {:ok, :erlang.binary_to_term(binary)}
    end
  end

  @impl true
  def delete(listener, client_id) do
    Repo.delete_all(
      from(s in @table, where: s.listener == ^listener and s.client_id == ^client_id)
    )

    :ok
  end

  @impl true
  def list(listener) do
    query = from(s in @table, where: s.listener == ^listener, select: {s.client_id, s.record})
    for {client_id, binary} <- Repo.all(query), do: {client_id, :erlang.binary_to_term(binary)}
  end

  @doc """
  Delete the sessions whose expiry has passed. Run it periodically (a cron
  job, Oban, Quantum): the broker deletes an expired session only from a
  node that held it, and nobody holds the sessions of a node that never
  came back. A session saved while its client was connected has no expiry
  here (its clock starts when a node loads it), so the rows of a node
  retired for good are deleted by `node`.
  """
  def sweep do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(s in @table, where: s.expires_at < ^now))
    count
  end

  # When a disconnected session ends; nil while its client is connected
  defp expires_at(%{meta: %{expires_at: at}}) when is_integer(at), do: DateTime.from_unix!(at)
  defp expires_at(_record), do: nil
end
```

```elixir
MqttX.Server.start_link(MyApp.MqttHandler, [],
  name: MyApp.Broker,
  port: 1883,
  session_backend: MyApp.MqttSessions
)
```

The callbacks run from one process per listener and node: `save` and
`delete` in the flush, once per changed session every
`:session_flush_interval` ms; `load` on a CONNECT for a session no running
node holds; `list` when the listener starts. A `save` that raises — the
database is down — is logged, the session stays marked, and the next flush
tries again, so nothing is lost while the node lives. Run `sweep/0` from a
scheduler: the broker deletes an expired session only from a node that
holds it.

## Session Expiry

MQTT 5.0 clients set `session_expiry_interval` in the CONNECT properties.
After the client disconnects, the server keeps the session that long, then
discards it and calls your `handle_session_expired/2` callback. The interval
is capped by the `:max_session_expiry_interval` transport option (default
86 400 s, one day; `:infinity` lifts the cap): a v5 client asking for more is
told the cap in CONNACK (§3.2.2.3.2), and a 3.1.1 client with CleanSession 0,
whose session would otherwise never end, is kept exactly that long.

The timer is supervised and **cancelled if the same client reconnects within
the window**, so expiry never fires for a session that resumed in time. A
client may also revise the interval in its DISCONNECT packet (§3.14.2.2.2) —
commonly `session_expiry_interval: 0` meaning "drop my session now".

```elixir
@impl true
def handle_session_expired(client_id, state) do
  # The broker has dropped the session's own state; drop yours
  MyApp.Devices.forget(client_id)
  :ok
end
```

| Value | Behavior |
|-------|----------|
| absent (v5) | Same as `0` |
| absent (3.1.1) | CleanSession 1: ends at disconnect; CleanSession 0: kept for `:max_session_expiry_interval` |
| `0` | Session ends at disconnect |
| `1..0xFFFFFFFE` | Session ends after N seconds (capped) |
| `0xFFFFFFFF` | Session never expires (capped) |

## Server-Initiated Disconnect

Kick a client from the server with an MQTT 5.0 reason code:

```elixir
# From outside the handler (e.g., admin action)
MqttX.Server.disconnect(transport_pid, 0x98)
MqttX.Server.disconnect(transport_pid, 0x89, %{reason_string: "Session taken over"})
```

Or return `{:disconnect, reason_code, state}` from any handler callback:

```elixir
@impl true
def handle_publish(topic, _payload, _opts, state) do
  if forbidden?(topic) do
    {:disconnect, 0x98, state}  # Use assigned client identifier
  else
    {:ok, state}
  end
end
```

DISCONNECT packets are only sent for MQTT 5.0 connections. For MQTT 3.1.1, the connection is simply closed.

The packet is made to arrive: the broker half-closes the socket and keeps
reading for up to 100 ms before closing it, so a client that is still
sending reads the DISCONNECT and then sees an orderly close, not a reset.

## MQTT 5.0 Protocol Features

The server automatically handles these MQTT 5.0 features when clients connect with protocol version 5:

### Topic Aliases

Clients can use topic aliases to reduce bandwidth by replacing repeated topic strings with short integer aliases. The server:

- Advertises `topic_alias_maximum: 100` in CONNACK (configurable via `transport_opts`)
- Resolves incoming topic aliases: first publish with alias + topic stores the mapping, subsequent publishes with alias only use the stored topic
- No application code needed — alias resolution is transparent to your handler callbacks

### Flow Control (Receive Maximum)

The server enforces `receive_maximum` for incoming QoS 1 and QoS 2 messages:

- Advertises `receive_maximum` in CONNACK (default: 65535, configurable via `transport_opts`)
- Tracks in-flight QoS 2 messages (between PUBREC and PUBCOMP)
- A client that sends more QoS > 0 publishes than that is disconnected with
  `0x93` (Receive Maximum exceeded) — the Protocol Error §4.9 prescribes;
  there is no per-message refusal code for it

In the other direction the broker honours the client's Receive Maximum:
outbound QoS > 0 publishes beyond the window wait in a per-connection queue
bounded by `:max_outbound_queue` (default 10 000, `:infinity` disables) and
are sent as acknowledgements free capacity, with any Message Expiry Interval
reduced by the time spent waiting and expired messages dropped. Outbound
Packet Identifiers are never reused while still in flight. A client that
connects with a zero-length client id is assigned one, which `handle_connect`
receives and a v5 client reads from the CONNACK's Assigned Client Identifier.

### Maximum Packet Size

Incoming packets are capped at **1 MiB by default** (since v0.11.0) and the
limit is enforced on the *declared* remaining length before the body is
buffered, so an unauthenticated peer cannot force a large allocation. Override
or disable it with `:infinity`:

```elixir
# NOTE: protocol options live in `transport_opts` inside the *handler options*
# (2nd argument), not the transport options (3rd argument).
MqttX.Server.start_link(
  MyApp.MqttHandler,
  [transport_opts: %{max_packet_size: 1_048_576}],
  transport: MqttX.Transport.ThousandIsland,
  port: 1883
)
```

- Server sends DISCONNECT with reason code `0x95` (Packet too large) for oversized incoming packets
- Retained storage is likewise bounded by `:max_retained_messages`
  (default 100_000 distinct topics)
- Outgoing publishes exceeding the client's advertised `maximum_packet_size` are silently dropped
- Server advertises its `maximum_packet_size` in CONNACK when configured

### Message Delivery Retry

MQTT §4.4 allows an unacknowledged QoS 1/2 PUBLISH or PUBREL to be re-sent
only when a session is resumed — never on a live connection, where TCP
already guarantees delivery and a missing acknowledgement means the peer is
slow or gone, which the keep-alive timeout detects. The broker therefore:

- Holds outgoing QoS 1/2 messages until the client acknowledges them, bounded
  by the client's Receive Maximum
- Holds an incoming QoS 2 message until PUBREL releases it, bounded by
  `:receive_maximum`
- Re-sends PUBREC only in reply to a duplicate PUBLISH (`dup: true`), without
  re-storing the message
- Runs no retransmission timer — `qos2_retry_interval` and `qos2_max_retries`
  are deprecated and ignored since 0.12.0

`MqttX.Server` does not persist sessions, so in-flight state ends with the
connection.

### Enhanced Authentication

A client that sends an Authentication Method in its CONNECT asks for an
MQTT 5.0 enhanced authentication exchange (§4.12). After `handle_connect`
accepts, the broker calls `handle_auth(method, data, state)` with the
CONNECT's Authentication Data (`nil` if none) and holds the CONNACK until the
exchange ends:

- `{:continue, challenge, state}` sends `AUTH 0x18` carrying `challenge`; the
  client's `AUTH 0x18` reply comes back through `handle_auth/3`
- `{:ok, state}` or `{:ok, server_final, state}` sends `CONNACK 0x00`, which
  repeats the Authentication Method (MQTT-4.12.0-5) and carries `server_final`
  as Authentication Data when given
- `{:error, reason_code, state}` sends a CONNACK with that code and closes the
  connection — `0x87` Not authorized for a failed proof, `0x8C` Bad
  authentication method for a mechanism you do not support

The same callback handles re-authentication (`AUTH 0x19`) on a live
connection, where success is `AUTH 0x00` and failure a DISCONNECT. During the
exchange any packet other than AUTH, an AUTH naming a different method, or an
AUTH with a reason code other than `0x18`, fails the CONNECT (`0x82` / `0x8C`);
a stalled exchange is ended by the CONNECT deadline, and a connection dropped
before CONNACK fires neither the Will nor `handle_disconnect/2`. An AUTH on a
connection whose CONNECT named no method is refused with `0x8C`.

The default `handle_auth/3` returns `{:error, 0x8C, state}`, so clients
asking for enhanced authentication are refused unless you implement it. The
mechanism itself — SCRAM, a token exchange — is yours to implement; see the
`handle_auth/3` docs on `MqttX.Server` for a SCRAM-shaped example.

### Shared Subscription Availability

The server advertises `shared_subscription_available: 1` in CONNACK. See
[Shared Subscriptions](#shared-subscriptions) under Topic Routing for usage.

### CONNACK Properties

For MQTT 5.0 connections, the server automatically includes these properties in CONNACK:

| Property | Value | Description |
|----------|-------|-------------|
| `shared_subscription_available` | `1` | Shared subscriptions supported |
| `topic_alias_maximum` | `100` | Max topic aliases the server accepts |
| `receive_maximum` | `65535` | Max in-flight QoS 1/2 messages |
| `maximum_packet_size` | *(if configured)* | Max incoming packet size in bytes |
| `retain_available` | `1` | Retained messages supported |
| `wildcard_subscription_available` | `1` | Wildcard subscriptions supported |
| `subscription_identifier_available` | `1` | Subscription identifiers attached to routed deliveries |

### Publish Properties

The `opts` map passed to `handle_publish/4` includes a `:properties` key containing any MQTT 5.0 publish properties sent by the client (e.g., `user_properties`, `content_type`, `correlation_data`, `response_topic`, `payload_format_indicator`, `message_expiry_interval`). These properties are also forwarded when the server sends outgoing PUBLISH messages via `handle_info/2`.

### Subscription Options

The server supports MQTT 5.0 subscription options:

- **`no_local`**: When set to `true`, messages published by a client are not delivered back to that client's own matching subscriptions. Requires passing the publisher identity to `Router.match/3`.
- **`retain_handling`**: Controls retained message delivery on subscribe:
  - `0` — Send retained messages (default)
  - `1` — Send retained messages if the subscription does not already exist
  - `2` — Do not send retained messages on subscribe

---

← Back to the [documentation index](../README.md#guides)
