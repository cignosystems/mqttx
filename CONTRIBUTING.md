# Contributing to MqttX

Notes for humans and AI assistants modifying this library itself. If you are
*using* MqttX in a project, see `README.md` and `AGENTS.md` instead.

## Repo layout shortcuts

- `lib/mqttx/packet/` — wire codec (`codec.ex`, `properties.ex`, `varint.ex`, `types.ex`)
- `lib/mqttx/topic.ex` — topic validation, normalization, wildcard matching, shared subs
- `lib/mqttx/transport/handler.ex` — per-connection broker state machine (~1000 LoC, big file)
- `lib/mqttx/server/` — broker pieces: `server.ex`, `router.ex`, `rate_limiter.ex`, `will_delay.ex`
- `lib/mqttx/client/connection.ex` — client GenServer (~1400 LoC)
- `lib/mqttx/client/websocket.ex` — RFC 6455 client framing
- `lib/mqttx/session/` — `Store` behaviour + ETS implementation; `ETSOwner` keeps the
  default `:mqttx_sessions` table alive under the application supervisor
- `lib/mqttx/payload/` — pluggable payload codecs (raw / json / protobuf)
- `test/mqttx/integration_test.exs`, `test/mqttx/interop_emqx_test.exs`,
  `test/mosquitto_validation.exs` — broker + client integration / interop suites

## Running tests

- Local unit + integration: `mix test --exclude interop`
- EMQX interop:
  `EMQX_HOST=du0.emmtry.com EMQX_PORT=8883 EMQX_USERNAME=350457794457489 EMQX_PASSWORD=Emmtry2 mix test test/mqttx/interop_emqx_test.exs --include interop`

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

- **Will Delay cancel-on-reconnect across nodes.** `MqttX.Server.WillDelay`
  cancels by client_id within a single BEAM. For a clustered setup, the cancel
  must be broadcast (Phoenix.PubSub or `:pg`).
- **Wildcard retained-message match on subscribe.** `deliver_retained_messages/2`
  does `:ets.foldl` over the entire retained table for any subscription that
  contains a `+`/`#`. Replace with a topic trie keyed by literal/`+`/`#` (with
  separate `$`-prefix root). Same data structure could back the subscription
  trie in `router.ex`.
- **Receive Maximum on the *client* (in-flight cap).** `connection.ex` exposes
  `:max_inflight` but doesn't honor the server's `receive_maximum` from CONNACK
  for outbound QoS>0. Threshold publishes when `state.inflight_tx_count >=
  server.receive_maximum`.

### Larger (each ~day-plus)

- **Route outbound PUBLISH through the router.** The handler currently
  `send_publish`es directly from the user callback's return values, bypassing
  the router. As a result `subscription_identifier`, `no_local`, and
  `retain_as_published` are computed but discarded. Refactor so `handle_info`
  publish-tuples and retained-on-subscribe paths fan out through
  `MqttX.Server.Router.match/3` and the per-subscription opts are applied per
  outbound PUBLISH.
- **Subscription matching trie in the router.** `MqttX.Topic.matches?/2` is
  linear; `Router.match/3` walks every subscription. For brokers serving >10K
  subscribers this is the dominant cost per publish. Replace with a per-level
  trie keyed by literal segment / `:single_level` / `:multi_level`, with a
  separate root for `$`-prefix topics. The current `Topic.matches?` semantics
  (already $-aware after the v0.10 fix) become the trie's per-edge semantics.
- **Persistent session store + expiry sweep.** `MqttX.Session.Store` covers
  CRUD on `subscriptions`, `pending_messages`, `packet_id`. Add (additively,
  no signature change to the behaviour) fields for QoS 2 inbound packet IDs,
  Will message + delay, session expiry timestamp. Spawn a sweeper that calls
  `delete/2` for expired sessions. Pre-existing comment in `ets_store.ex`
  explicitly notes lack of restart durability.
- **Server-side receive buffer iolist.** `handler.ex:handle_data/2` accumulates
  incoming bytes via `buf <> data` — O(n²) on fragmented large packets. Same
  pattern in `connection.ex:handle_info({:tcp, …})`. Switch to iolist
  accumulation with `IO.iodata_to_binary/1` only at decode time.
- **Max packet size enforced before decode.** Currently `process_buffer/2`
  decodes the whole packet then checks `byte_size(buffer) - byte_size(rest) >
  server_max_packet_size`. An attacker sending a 100MB packet still gets it
  fully buffered before rejection. Inspect the variable byte integer in the
  fixed header first; if `remaining_length` is out of policy, send DISCONNECT
  0x95 and close before any payload allocation.

### API-changing (worth a v0.11 deliberate bump)

- **Payload codec PFI / content-type wiring.** `MqttX.Payload` callbacks are
  `encode/1`/`decode/1`. To auto-set `:payload_format_indicator` and
  `:content_type` (MQTT 5.0 §3.3.2.3.2/9) the behaviour signature has to
  change — either a `metadata/0` callback returning `%{pfi: 0|1, content_type:
  String.t()}` or augmenting encode/decode return tuples. Tied to a clean
  major bump.

### Smaller polish (low risk, do whenever)

- `MqttX.Topic.is_wildcard?/1` is a `is_*` predicate but isn't a guard.
  Rename to `wildcard_part?/1` to match Credo conventions.
- Several reason-code literals (`0x82`, `0x94`, `0x95`, `0x93`, `0x92`, `0x8C`,
  `0x84`, `0x18`) appear inline across `handler.ex`. Pull to a shared
  module attribute file (`MqttX.Packet.ReasonCodes`).
- Packet-type and property-id constants are duplicated in `types.ex`,
  `codec.ex`, and `properties.ex`. Pick one source of truth.
- `connection.ex` is a 1400-line monolithic GenServer. Split connect/handshake,
  retry logic, topic-alias logic into helper modules.
- `MqttX.Topic.flatten/1` switched from binary concat to iodata, but other
  paths (`handler.ex:normalize_topic_key/1` etc.) still do `Enum.join("/")` per
  call — fine for retained delivery but worth sharing a single helper.
