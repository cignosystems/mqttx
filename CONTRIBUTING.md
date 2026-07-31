# Contributing to MqttX

Notes for humans and AI assistants modifying this library itself. If you are
*using* MqttX in a project, see `README.md` and `AGENTS.md` instead.

## Repo layout shortcuts

- `lib/mqttx/packet/` — wire codec (`codec.ex`, `properties.ex`, `varint.ex`, `types.ex`)
- `lib/mqttx/topic.ex` — topic validation, normalization, wildcard matching, shared subs
- `lib/mqttx/transport/handler.ex` — per-connection broker state machine (~1900 LoC, big file)
- `lib/mqttx/server/` — broker pieces: `server.ex`, `router.ex`, `rate_limiter.ex`, `will_delay.ex`
- `lib/mqttx/client/connection.ex` — client GenServer (~2200 LoC)
- `lib/mqttx/client/websocket.ex` — RFC 6455 client framing
- `lib/mqttx/session/` — `Store` behaviour + ETS implementation; `ETSOwner` keeps the
  default `:mqttx_sessions` table alive under the application supervisor
- `lib/mqttx/payload/` — pluggable payload codecs (raw / json / protobuf)
- `test/mqttx/integration_test.exs`, `test/mqttx/interop_emqx_test.exs`,
  `test/mosquitto_validation.exs` — broker + client integration / interop suites

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

### Larger (each ~day-plus)

- **Route outbound PUBLISH through the router.** The handler currently
  `send_publish`es directly from the user callback's return values, bypassing
  the router. As a result `subscription_identifier`, `no_local`, and
  `retain_as_published` are computed but discarded. Refactor so `handle_info`
  publish-tuples and retained-on-subscribe paths fan out through
  `MqttX.Server.Router.match/3` and the per-subscription opts are applied per
  outbound PUBLISH.
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

### API-changing (worth a v0.11 deliberate bump)

- **Payload codec PFI / content-type wiring.** `MqttX.Payload` callbacks are
  `encode/1`/`decode/1`. To auto-set `:payload_format_indicator` and
  `:content_type` (MQTT 5.0 §3.3.2.3.2/9) the behaviour signature has to
  change — either a `metadata/0` callback returning `%{pfi: 0|1, content_type:
  String.t()}` or augmenting encode/decode return tuples. Tied to a clean
  major bump.

### Smaller polish (low risk, do whenever)

- Several reason-code literals (`0x82`, `0x94`, `0x95`, `0x93`, `0x92`, `0x8C`,
  `0x84`, `0x18`) appear inline across `handler.ex`. Pull to a shared
  module attribute file (`MqttX.Packet.ReasonCodes`).
- Packet-type and property-id constants are duplicated in `types.ex`,
  `codec.ex`, and `properties.ex`. Pick one source of truth.
- `connection.ex` is a ~2200-line monolithic GenServer. Split connect/handshake,
  retry logic, topic-alias logic into helper modules.
- `MqttX.Topic.flatten/1` switched from binary concat to iodata, but other
  paths (`handler.ex:normalize_topic_key/1` etc.) still do `Enum.join("/")` per
  call — fine for retained delivery but worth sharing a single helper.
