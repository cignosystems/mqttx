# Contributing to MqttX

Notes for humans and AI assistants modifying this library itself. If you are
*using* MqttX in a project, see `README.md` and `AGENTS.md` instead.

## Repo layout shortcuts

- `lib/mqttx/packet/` — wire codec (`codec.ex`, `properties.ex`, `varint.ex`) and `buffer.ex`, the receive-side
  reassembly buffer shared by the broker handler and the client
- `lib/mqttx/topic.ex` — topic validation, normalization, wildcard matching, shared subs
- `lib/mqttx/transport/handler.ex` — per-connection broker state machine (~1900 LoC, big file)
- `lib/mqttx/server/` — broker pieces: `server.ex`, `router.ex`, `retained_store.ex`, `rate_limiter.ex`, `will_delay.ex`,
  `session_store.ex` (Session State in ETS), `delivery.ex` (`deliver/3`), `cluster.ex` (one broker across
  nodes; `cluster/relay.ex` sends to the other nodes and keeps the route table) and `session_backend.ex`
  (durable sessions; `session_backend/dets.ex`, `session_backend/replicated.ex`)
- `lib/mqttx/client/connection.ex` — client GenServer (~2200 LoC)
- `lib/mqttx/client/websocket.ex` — RFC 6455 client framing
- `lib/mqttx/session/` — `Store` behaviour + ETS implementation; `ETSOwner` keeps the
  default `:mqttx_sessions` table alive under the application supervisor
- `lib/mqttx/payload/` — pluggable payload codecs (raw / json / protobuf)
- `test/mqttx/integration_test.exs`, `test/mqttx/interop_emqx_test.exs`,
  `test/mosquitto_validation.exs` — broker + client integration / interop suites
- `test/support/` — compiled test helpers: `MqttX.Test.FakeBroker`, a scriptable
  TCP "broker" that relays what the client sends to the test process (use it to
  put the client in a state a real broker would not), and
  `MqttX.Test.ForwardingHandler`, and `MqttX.Test.TLSFixtures`, which writes
  the TLS tests' private CA and `localhost` certificate into
  `test/fixtures/tls/` when the suite starts — the directory is gitignored,
  so no private key is ever committed
- `bench/` — Benchee suites (`codec.exs`, `server.exs`, `e2e.exs`);
  `test/mqttx/load_test.exs` — end-to-end load validation (`--include load`)

## Running tests

- Local unit + integration: `mix test --exclude interop`
- EMQX interop — runs against any reachable EMQX. The easiest is a local
  Docker one (it ships a self-signed TLS listener on 8883 out of the box,
  which is fine because the suite connects with `verify: :verify_none`):

  ```sh
  docker run -d --name emqx -p 1883:1883 -p 8883:8883 emqx/emqx
  EMQX_HOST=localhost EMQX_PORT=8883 \
    mix test test/mqttx/interop_emqx_test.exs --include interop
  ```

  Note: with default EMQX config anonymous access is allowed, so the
  "rejects wrong credentials" test is only meaningful against a broker with
  password auth enabled (set `EMQX_USERNAME`/`EMQX_PASSWORD` accordingly).
- Load validation — many clients, many messages, real sockets; asserts
  completeness (every message arrives exactly as often as it should, every
  QoS 1 publish is acknowledged, nothing disconnects), not speed:

  ```sh
  mix test --include load
  ```

## Benchmarks

`bench/` holds [Benchee](https://hex.pm/packages/benchee) suites (dev
dependency). Each takes `BENCH_TIME` (seconds per scenario) and prints a
Benchee table; `e2e.exs` adds a messages-per-second summary.

```sh
mix run bench/codec.exs      # encode/decode per packet type
mix run bench/server.exs     # Router.match, RetainedStore.match, receive-buffer reassembly
mix run bench/e2e.exs        # client <-> broker over loopback: uplink QoS 0/1, fan-out 1 -> N
BENCH_TRANSPORT=ws BENCH_SUBSCRIBERS=20 mix run bench/e2e.exs
```

When a change moves a hot path, refresh the numbers in
`guides/performance.md` from these — do not reason about them from first
principles. Two of the fixes in 0.12 (retained-store match specs, the
receive buffer) were quadratic paths that only showed up under measurement.

## Known test environment couplings

The `MqttX.ClientTest` suite (~11 tests) hardcodes `localhost:1883` and asserts
that the connection fails with `:not_connected` after a 100ms sleep. If a
broker is running on `localhost:1883` (mosquitto, EMQX, etc.) those tests
fail because the client actually connects. **These are not regressions.** The
proper fix is to either spin up an isolated test broker on a unique port or
mock the socket — flagged as a future cleanup.

## TODO (deferred from the v0.10.0 spec/quality sweep)

These items came out of a deep audit + fix pass against MQTT 5.0. Critical and
quick-win items have been fixed; what's listed here is the residual work,
ordered roughly by ratio of impact to effort.

### Medium (each ~half-day)

- **Clustering follow-ups.** The phases in `docs/design/clustering.md` are
  done; its "Later" list has what remains (exactly-once shared delivery
  across a node loss, a database backend example).
  `test/mqttx/cluster_test.exs` runs real nodes with `:peer` (needs epmd).

### Smaller polish (low risk, do whenever)

- `connection.ex` (~2000 lines): the proxy tunnel and topic-alias logic are
  extracted (`MqttX.Client.Proxy`, `MqttX.Client.TopicAlias`); the in-flight
  tracking and the session-resume re-send are still inline because they are
  entangled with `send_packet/2` socket I/O — extracting them means threading
  a send callback through, so do it only as part of a deliberate
  connect/handshake split.

Done in this section: reason-code literals in `handler.ex` are named via
`MqttX.Packet.ReasonCodes`; packet-type/property-id constants have one source
of truth each (`codec.ex` / `properties.ex` — the duplicate `types.ex` was
removed); topic joins share `MqttX.Topic.flatten/1` (which is wildcard-aware,
unlike the `Enum.join("/")` calls it replaced); wildcard retained-message
match on subscribe no longer folds the whole table through Elixir —
`MqttX.Server.RetainedStore` keys rows by segment list in an `:ordered_set`
and compiles each filter to an ETS match spec, so a literal prefix bounds the
traversal (the `$`-guard and size cap moved there too, deduplicating
`handler.ex` and `will_delay.ex`); outbound PUBLISH routes through the router
— the handler keeps a per-connection `MqttX.Server.Router`, `handle_info`
publish-tuples fan out through `Router.match/3` with per-subscription opts
applied (granted-QoS cap, retain-as-published, no_local via a `:publisher`
opt, subscription identifiers), retained-on-subscribe carries the
subscription identifier, and CONNACK now advertises
`subscription_identifier_available: 1`; the persisted client session carries
`expires_at`/`saved_at` from the negotiated Session Expiry Interval, an
expired record is discarded on load, `MqttX.Session.ETSOwner` sweeps every
table it owns, and a clean start calls `delete/2` as the store contract
always said (QoS 2 inbound ids were already persisted as `{:rx, id}`
entries); the broker keeps Session State (§4.1) in `MqttX.Server.SessionStore`
— ETS per listener: a subscription index walked by key order, in-flight state
mirrored for sessions that outlive their connection, a per-session queue —
with `MqttX.Server.Delivery` as the fan-out behind `MqttX.Server.deliver/3`
(queue first, then poke the connection, so a closing connection cannot lose
a message); receive-side reassembly is linear — `MqttX.Packet.Buffer` waits
for a packet's declared length and flattens once instead of `buf <> data` plus
a decode attempt per read (which re-copied the whole buffer every time), used
by `handler.ex`, the client's TCP/TLS path and its WebSocket frame buffer;
the client now applies `:max_packet_size` to every packet, not just the first
in a read; payload codecs declare their PFI / content type through an
*optional* `metadata/0` callback (so no signature change was needed) and both
publish paths take a `:codec` option that encodes the term and merges that
metadata into the properties.
