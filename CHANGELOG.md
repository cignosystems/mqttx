# Changelog

All notable changes to this project will be documented in this file.

## [0.11.1] - 2026-07-31

### Fixed

- **README links render correctly on hex.pm's package page.** The page shows
  the README from the package tarball and rewrites relative links to the raw
  file server (`repo.hex.pm/preview/...`), which serves guide pages as plain
  text. All relative documentation links in the README are now absolute
  hexdocs.pm URLs, which work on hexdocs, GitHub, and hex.pm alike; a
  documentation test resolves each one back to its source file and verifies
  the page and heading anchor exist.

## [0.11.0] - 2026-07-31

A security and correctness release. Every Critical and High finding from a
full-codebase audit is fixed, several features that were silently broken now
work (the Ranch transport, inbound topic aliases, reconnect resubscription,
dead-link detection), and two long-requested features land: `use MqttX` and
HTTP CONNECT proxy support.

**Upgrading:** some defaults change deliberately — read **Changed** first. The
most likely surprise is TLS certificate verification, which is now on by
default.

### Changed (breaking defaults)

- **Client TLS verifies certificates by default.** `:ssl` and `:wss` use
  `verify: :verify_peer` with the OS trust store
  (`:public_key.cacerts_get/0`), SNI, HTTPS-style hostname checking, and TLS
  1.2/1.3 only. Your `:ssl_opts` are merged *over* that baseline, so
  `verify: :verify_none` still works — explicitly, and with a logged warning.
  Setups that silently relied on no verification will now fail until
  certificates are configured; that is the point.
- **Server TLS baseline.** When a TLS transport is selected, the
  ThousandIsland and Ranch adapters inject
  `versions: [:"tlsv1.3", :"tlsv1.2"]`, `secure_renegotiate: true`, and
  `honor_cipher_order: true` beneath your `:transport_options`.
- **Server `max_packet_size` defaults to 1 MiB** (was unlimited) and is
  enforced on the *declared* remaining length before the body is buffered,
  closing a pre-auth memory-exhaustion vector. `max_packet_size: :infinity`
  restores the old behavior.
- **Client `max_packet_size` defaults to 1 MiB**, applying the same check to
  data from the broker.
- **Socket liveness no longer depends on Keep Alive alone.** ThousandIsland's
  60 s `read_timeout` was disconnecting spec-compliant clients whose keepalive
  exceeded it, so it now defaults to `:infinity`; in its place the protocol
  handler enforces `:max_idle_timeout` (default 15 min, `:infinity` disables),
  which resets on any inbound data and therefore also covers clients that
  negotiate `keep_alive: 0`. A separate `:connect_timeout` (default 10 s)
  closes sockets that never complete CONNECT.
- **Ranch transport selection renamed to `:ranch_transport`**
  (`:ranch_tcp` | `:ranch_ssl`). The old `:transport` key collided with
  `MqttX.Server`'s own `:transport` option (the adapter module) — a collision
  that made the documented Ranch setup fail at startup. `:transport` is still
  honored when it holds a valid ranch atom.
- **The client discards in-flight QoS 1/2 state when the broker starts a fresh
  session** (`session_present: false`, MQTT-3.2.2-4), with a warning, instead
  of retaining state it can never deliver.
- **`MqttX.Client.connect/1` no longer waits for CONNACK.** The handshake is
  now event-driven, so `connect/1` returns before the session is live and a
  `subscribe`/`publish` issued immediately after it returns
  `{:error, :not_connected}`. Previously the blocking handshake made such calls
  queue in the mailbox until CONNACK, so they appeared to succeed. Either act on
  the handler's `:connected` event, or pass the new **`await_connect: true`**
  option to block until the first attempt resolves — that form returns
  `{:error, reason}` (e.g. `:econnrefused` or `{:connack_error, code, info}`)
  and stops the client if the attempt failed. The asynchronous default is
  deliberate: a client can now be started before its broker is reachable and
  keep retrying with backoff, which a blocking connect cannot do.
- **Malformed packets close the client connection** (§4.13) instead of being
  logged and left at the head of the buffer, which wedged all further decoding
  and grew the buffer without bound. Handlers see
  `(:disconnected, {:protocol_error, reason})` and the client reconnects.

### Added

- **`use MqttX` — module-based client** (GitHub #1). Define a client as one
  module with `init/1`, `handle_message/4`, `handle_connected/2`,
  `handle_disconnected/2`, `handle_publish_error/4`, and `handle_info/2` (all
  defaulted), add it to a supervision tree as `{MyClient, connect_opts}`, and
  use the injected `publish`/`subscribe`/… helpers — including from inside
  callbacks, which run in the module's own process and so cannot deadlock the
  connection. See `MqttX.SimpleClient`.
- **HTTP CONNECT proxy support** (GitHub #2). Pass
  `proxy: [host: "proxy.corp", port: 3128, auth: {"user", "pass"}]` to tunnel
  any transport (`:tcp`/`:ssl`/`:ws`/`:wss`) through a forward proxy
  (RFC 9110 §9.3.6). TLS and the WebSocket upgrade layer over the established
  tunnel, so certificate verification and SNI target the broker, not the
  proxy. Basic auth is supported; a non-200 response fails the attempt with
  `{:proxy, {:proxy_status, code}}` and backs off normally.
- **Automatic resubscription.** Granted subscriptions are recorded on SUBACK
  and replayed after any reconnect reporting `session_present: false`.
  Previously they were never tracked, so a transient disconnect left the
  client connected but deaf. Tracked subscriptions persist via
  `:session_store`.
- **Prompt in-flight resend on session resumption** (§4.4/§4.6). On CONNACK
  with `session_present: true`, unacknowledged QoS 1/2 PUBLISHes (dup=1) and
  PUBRELs are resent immediately in original submission order — not up to
  `retry_interval` later in arbitrary map order.
- **`MqttX.Packet`** — public façade for the codec (`encode/2`, `decode/2`,
  `encode_iodata/2`, `declared_length/1`). The landing-page docs referenced
  this module before it existed.
- `MqttX.Packet.Codec.declared_length/1` — the wire size a buffered packet
  declares, readable from its first bytes; used for early size enforcement.
- New handler event `(:publish_error, {topic, packet_id, reason_code})` and
  telemetry event `[:mqttx, :client, :publish, :exception]` for broker-rejected
  QoS 1/2 publishes.
- Server options `:max_idle_timeout`, `:connect_timeout`,
  `:max_retained_messages`, ThousandIsland `:read_timeout`, and WebSocket
  `:max_frame_size`; client options `:max_packet_size` and `:await_connect`.
- `:ssl` and `:public_key` added to `extra_applications`, so TLS transports
  work inside Mix releases without the host app listing them.

### Fixed — remote crashes and DoS

- **Codec crashes reachable from the network.** CONNACK / v5 PUBACK / PUBREC /
  PUBCOMP / PUBREL / DISCONNECT / AUTH packets with trailing bytes after their
  properties raised `CaseClauseError`; v3/v4 acks with bytes after the packet
  id raised `FunctionClauseError`. Both now return
  `{:error, :malformed_packet}`. Truncated content *inside* a complete packet
  (property-length overrun, truncated UTF-8) was misreported as
  `:incomplete`, wedging client and server buffers — now `:malformed_packet`.
- **A truncated varint inside a property slice crashed the decoder.**
  `Varint.decode/1` returns a bare `:incomplete`, and the
  Subscription Identifier decoder's `with` had no `else`, so that atom escaped
  into `Properties.decode/2` and raised `CaseClauseError`. Eight bytes were
  enough to kill a connection process, on client and server alike. Found by
  the new property-based fuzzing (1 failure in ~80 000 bit-flipped packets),
  now returns `{:error, :malformed_packet}`; the property-decode boundary also
  rejects any unexpected shape defensively rather than raising.
- **Unauthenticated peers could suppress another client's Last Will.**
  `WillDelay.cancel/1` and `SessionExpiry.cancel/1` ran at the top of CONNECT,
  before authorization; they now run only after the handler accepts the
  connection, alongside session takeover.
- **Unbounded buffering from a hostile broker.** The client now enforces a
  declared-length packet cap, and the WebSocket client caps a single frame's
  declared payload (a 64-bit length field previously had no ceiling).
- **Proxy hardening.** CR/LF, whitespace, and NUL in `:host` are rejected
  before they can inject headers into the CONNECT request, and a non-numeric
  proxy status no longer raises inside the connection process.
- Retained storage is bounded by `:max_retained_messages` (default 100 000
  topics) and written only after the handler *accepts* the publish, so
  unauthorized publishers cannot fill it. A delayed Will's retained write
  respects the same cap.
- The client honors the Topic Alias Maximum it advertised, rejecting larger
  aliases from the broker.
- `WillDelay` / `SessionExpiry` timers are keyed by `{listener, client_id}`,
  matching session takeover's scope, so two brokers in one VM cannot cancel
  each other's timers.

### Fixed — client

- **The blocking CONNECT handshake is gone.** The client no longer sits in a
  bare `receive` between CONNECT and CONNACK: the handshake runs through the
  normal GenServer loop in a `:connecting` state. Calls answer immediately
  during a (re)connect; one *total* handshake deadline applies, so a broker
  trickling AUTH packets can no longer hold the client open indefinitely; and
  a CONNACK split across TCP segments now reassembles correctly. The deadline
  is generation-tagged so a late timeout cannot abort a later handshake.
- **Dead-link detection works.** The PINGRESP deadline was cancelled and
  re-armed by every keepalive tick (1.0×K tick vs 1.5×K deadline), so it could
  never fire and a black-holed connection was never detected. An unanswered
  PINGREQ's deadline now stands, and stale pingresp/keepalive/retry timers are
  cancelled on every teardown path so they cannot kill the next connection.
- **Supervised clients can be disconnected.** `Connection` ships a
  `restart: :transient` child spec, so `disconnect/2`'s normal stop is no
  longer resurrected by the DynamicSupervisor into an immediate reconnect.
  Calling `disconnect/2` while offline no longer crashes on
  `:gen_tcp.send(nil, _)`.
- **Non-retryable CONNACK rejections stop the client** rather than reconnecting
  forever: bad credentials (0x86/0x04), not authorized (0x87/0x05), invalid
  client id (0x85/0x02), unsupported version (0x84/0x01), banned (0x8A), bad
  auth method (0x8C). Handlers receive
  `(:disconnected, {:connack_error, code, info})` and the process exits
  normally; transient failures still retry with backoff.
- **Inbound topic aliases never resolved** — a type mismatch delivered every
  aliased PUBLISH with topic `""`. Aliased messages now carry the real topic,
  alias maps reset per connection in both directions, and an unknown alias is
  a protocol error (§3.3.2.3.4).
- **QoS retries no longer replay stale topic-alias state** across reconnects:
  pending entries store the original topic with no alias property, so a retry
  cannot trigger a broker protocol error or rebind an alias to another topic.
- PUBACK/PUBREC error reason codes (>= 0x80) are surfaced — warning log,
  `:publish_error` handler event, exception telemetry — instead of counted as
  success, and an error PUBREC no longer triggers a spec-violating PUBREL.
- A PUBREL for an id the client no longer tracks is answered with PUBCOMP
  (0x92 in v5) instead of ignored, so a lost PUBCOMP no longer leaves the
  broker retrying forever.
- Inbound QoS 2 messages are bounded by the client's advertised Receive
  Maximum (DISCONNECT 0x93 if the broker exceeds it).
- Packet-id allocation skips ids held by in-flight SUBSCRIBE/UNSUBSCRIBE
  (shared id space, §2.2.1) and returns `{:error, :packet_ids_exhausted}`
  rather than reusing a live id; callers blocked in subscribe get
  `{:error, :not_connected}` immediately on disconnect instead of a timeout.
- The client traps exits and implements `terminate/2`, so supervisor/VM
  shutdown sends a clean DISCONNECT (no spurious will) and saves the session.
- Session-store failures (init/load/save) are logged instead of silently
  disabling requested persistence; custom `ETSStore` tables are created via
  the supervised `ETSOwner` (they used to be owned by the connection process
  and died in the very crash they existed to survive).
- The WebSocket client honors control frames: Pings get matching Pongs
  (proxies liveness-check this way), a Close triggers a proper reply and
  teardown, and fragmentation state resets per connection.
- Handler callbacks are isolated — a raising `handle_mqtt_event/3` is logged
  instead of taking down the connection (which could poison-loop on QoS 1
  redelivery) — and `Code.ensure_loaded?` runs before the callback check, so a
  not-yet-loaded handler module in dev/iex no longer discards every event.
- `publish(client, topic, payload, qos: 3)` returns `{:error, :invalid_qos}`
  instead of sending a malformed packet and crashing the connection.
- `MqttX.Client.connect/1` returns
  `{:error, {:missing_option, :host | :client_id}}` instead of raising
  `KeyError`; its `@spec` is widened to
  `GenServer.on_start() | {:error, term()}`.
- Reconnect backoff state was discarded on several failure paths (the timer
  fired but the delay never grew); `:jitter` is clamped to [0, 0.9], since
  values >= 1 could produce a negative delay and crash `Process.send_after`.

### Fixed — broker / server

- **The Ranch adapter was non-functional.** `:ranch.handshake/1` ran inside
  `GenServer.init/1`, deadlocking ranch's connection supervisor on the first
  inbound connection; it now uses the documented
  `:proc_lib.spawn_link` + `enter_loop` pattern. Also fixed there: TLS
  (`{:ssl, ...}`) messages were handed to the user handler instead of the MQTT
  decoder, and close/stop paths skipped `handle_close`, so wills,
  `handle_disconnect`, and session expiry never ran on Ranch.
- **Session takeover (§3.1.4-3)**: a CONNECT reusing a live client_id now
  disconnects the incumbent (0x8E) and takes over, via a per-listener
  registry. Two connections could previously share a client_id indefinitely.
- **Session expiry is supervised and cancellable** — the
  `Task.start + Process.sleep` timers were uncancellable and fired even for
  clients that had reconnected, wiping live sessions. Replaced by
  `MqttX.Server.SessionExpiry`, mirroring `WillDelay`; a fresh CONNECT for the
  same client_id cancels the pending expiry.
- **A second CONNECT on a live connection is a protocol error** (0x82,
  §3.1.0-2) instead of re-running auth, sending a second CONNACK, and leaking
  a keepalive timer that would later tear down the session and spuriously
  publish the will.
- **Client Receive Maximum is enforced on outbound QoS > 0** (§3.3.4): sends
  beyond the advertised window queue and drain as acks arrive, instead of
  flooding constrained clients into a DISCONNECT 0x93.
- **Retained deliveries at QoS > 0 are tracked in flight**, routed through the
  normal send path — a QoS 2 retained delivery now completes its
  PUBREC/PUBREL/PUBCOMP handshake (the PUBREC used to be ignored and the flow
  hung forever) and QoS 1 retained deliveries retransmit on loss.
- **Shared subscriptions are keyed by the (ShareName, TopicFilter) pair**
  (§4.8.2). One group name across several filters previously collapsed into a
  single group, and the second filter's traffic reached nobody.
- Idle timeouts publish the will and start session expiry like any other
  abnormal close.
- **WebSocket stop paths deliver queued frames**: rejection CONNACKs and
  DISCONNECT packets are sent before the close frame instead of being
  discarded, so WS clients can distinguish auth failure from a network blip.
  The rate-limited upgrade path returns its 1008 close code correctly.
- `handle_disconnect/2` fires exactly once per connection (it previously ran
  twice, sometimes three times, across the inline and terminate paths).
- v5 DISCONNECT properties are honored: a revised `session_expiry_interval`
  (e.g. 0 for "drop my session now") takes effect, and a 0 → non-zero revision
  is rejected as a Protocol Error (§3.14.2.2.2).
- Will Delay honors session end (§3.1.2.5): with session expiry 0 the will
  publishes immediately on abnormal disconnect, otherwise at
  min(delay, session expiry).
- Enhanced re-authentication (§4.12.1) answers with AUTH 0x00 on success and
  DISCONNECT on failure — never a second CONNACK.
- PUBREC with an error reason aborts the QoS 2 flow without PUBREL; an unknown
  packet id is answered with PUBREL 0x92 (v5).
- `retain_handling: 1` is honored (retained messages only for new
  subscriptions), and retained delivery is capped at the *granted* QoS rather
  than the requested one.
- v3.1.1 CONNECT with a zero-byte ClientID and CleanSession=0 is rejected with
  0x02 (MQTT-3.1.3-8).
- `Router.match/2,3` delivers at the maximum QoS across a client's overlapping
  subscriptions (§3.3.4) instead of an arbitrary one; only
  `match_and_advance/3` advances shared-group round-robin, now documented.

### Removed

- **`MqttX.Packet.Types`** — 93 constant-accessor functions (packet type
  numbers, reason codes, property identifiers) with no callers anywhere in the
  library, tests, or documentation; the codec carries its own constants. Codec
  users are unaffected: the public entry points are `MqttX.Packet` /
  `MqttX.Packet.Codec`, which speak maps and atoms — the numeric wire
  constants were never part of the API surface.

### Fixed — codec

- Malformed SUBACK/UNSUBACK reason bytes fail the whole decode; previously the
  packet decoded "successfully" with the error buried in the `acks` list.
  Empty SUBACK (and v5 UNSUBACK) ack lists are rejected.
- Strings and binaries over 65 535 bytes return `{:error, :string_too_long}`
  on encode instead of silently wrapping the 16-bit length prefix and
  corrupting the wire (topics, client_id, credentials, will data, and every
  string/binary property). `Topic.validate/1` applies the same cap to
  list-form topics.
- Packet ids are validated on encode — `{:error, :missing_packet_id}` for
  absent or zero ids on QoS > 0 PUBLISH, acks, and (un)subscribe packets,
  which previously encoded as `0x0000` and had to be rejected by every
  receiver.
- PUBLISH encode validates QoS (0-2) and the topic (no wildcards, non-empty
  unless a topic alias is set); SUBSCRIBE/UNSUBSCRIBE reject empty topic
  lists; CONNECT rejects an out-of-range keepalive.
- Property values are range-checked on encode (32/16-bit integers, varint
  subscription identifiers), and unknown or mistyped properties return
  `{:error, {:invalid_property, name}}` instead of vanishing from the wire.
- UTF-8 validity (no U+0000, no surrogates) is enforced on encode, matching
  decode. The Will payload and password are correctly treated as binary data
  rather than UTF-8 strings.
- v3.1.1 SUBSCRIBE: v5-only subscription option bits (nl/rap/rh) are rejected
  on decode (§3.8.3-4) and never emitted on encode.
- `MqttX.Payload.JSON` is always defined; on runtimes without the native
  `JSON` module it returns `{:error, :json_not_available}` instead of the
  module simply not existing.

### Tooling, docs, and tests

- **CI matrix extended to Elixir 1.20 / OTP 29** (released since 0.10.0):
  the test job now covers 1.18/27 (the `mix.exs` floor), 1.19/28, 1.20/28, and
  1.20/29; the dialyzer and publish jobs run on 1.20/29. The README's quoted
  range is pinned to the workflow file by a test.
- **All compiler warnings cleared** — `mix compile --warnings-as-errors`, which
  CI runs and which gates the release job, now passes. Twelve were unreachable
  `atom_to_type/1` clauses; three were unpinned bitstring size variables.
- Dialyzer configured (`plt_add_apps` for the optional transports);
  `stream_data` added for property-based tests. **`mix dialyzer` now passes
  cleanly**, which matters because the release job declares
  `needs: [test, dialyzer]` — two errors were failing it:
  - `MqttX.Server.WillDelay`'s `ctx()` type omitted `:max_retained_messages`,
    a key the module itself reads when republishing a delayed Will. The type
    and the code had disagreed since the retained-message cap was added.
  - The Will delay passed to `WillDelay.schedule/4` was only inferred as
    `integer()`, not the `non_neg_integer()` the contract requires. The values
    do come from 32-bit unsigned properties, but nothing enforced it; a float
    or negative reaching `Process.send_after/3` would crash the supervised
    `WillDelay` process and silently drop the Will. The invariant is now
    enforced at the boundary by a guarded `will_delay_ms/1`.
- Removed a defensive `_other` clause in `MqttX.Packet.Properties.decode/2`
  that dialyzer proved unreachable: it guarded against a property decoder
  leaking a bare atom, which is now prevented at its source by the explicit
  `else` on the `Varint.decode/1` `with`. `decode_utf8/1` and `decode_binary/1`
  were confirmed to return proper `{:error, _}` tuples.
- Dependencies refreshed: `thousand_island` 1.5.0, `bandit` 1.12.4,
  `telemetry` 1.4.2, `ranch` 2.2.1, `protox` 2.0.9, `ex_doc` 0.40.3.
- **`websock_adapter` requirement widened to `~> 0.5 or ~> 0.6`.** 0.6.0 makes
  no API change — its only change is a default `max_frame_size` of 10 MB
  (previously `:infinity`) — but the old `~> 0.5` requirement excluded it and
  would have blocked installation for any app already on 0.6. The WebSocket
  transport gained a `:max_frame_size` option so this limit can be set
  explicitly rather than varying with the resolved adapter version.
- **Documentation overhaul.** Installation and Quick Start moved to the top of
  the README, with the cellular-IoT analysis extracted to a new
  *Why MQTT for IoT* guide. `use MqttX`, the proxy option, the secure-TLS
  default, the `:publish_error` event, and the new server options are
  documented across the README, guides, `AGENTS.md`, and moduledocs. Telemetry
  docs now state the real topic shape (inbound events carry decoded segment
  lists, not binaries) and list the new exception event.
- **Documentation examples are now tested** (`documentation_test.exs`): every
  fenced `elixir` block in the README, guides, and `AGENTS.md` must parse, every
  `MqttX.*` function it calls must exist at that arity, `transport:` values
  must name real modules, and the declared `{:mqttx, "~> x.y"}` version must
  match `mix.exs`. This caught a landing-page example that raised
  `UndefinedFunctionError` and a guide pinning an outdated version.
- **Fixed the `websock_adapter` requirement in the install instructions.** The
  README, `AGENTS.md`, and the getting-started and server guides all told users
  to add `{:websock_adapter, "~> 0.5"}` — the very requirement that was widened
  to `"~> 0.5 or ~> 0.6"` in `mix.exs`, so anyone copying the snippet
  re-created the resolution failure the widening was meant to fix. All four now
  match, and a test pins every documented dependency requirement to `mix.exs`.
- **`guides/server.md` now documents every server callback.** `handle_puback/2`
  and `handle_auth/3` were missing from the "Callback Summary" table, so a
  broker author could not discover MQTT 5.0 enhanced authentication or QoS 1
  delivery confirmation from the guide. The table is now pinned to
  `MqttX.Server.behaviour_info(:callbacks)` by a test.
- **The clean-session limitation is no longer buried.** The note that
  `session_present` is always `false` sat as an H3 inside "MQTT 5.0 Protocol
  Features", though it applies to every protocol version; it is now a top-level
  *Session State* section next to *Session Expiry*.
- **Duplicated examples consolidated to one canonical copy.** The handler
  example, the `use MqttX` example, and the codec benchmark table each existed
  in three to five places and had already drifted apart. The guides are now
  canonical for how-to material and the README links to them; the copies that
  must stay (`AGENTS.md`, which is meant to be self-contained, and moduledocs,
  which must stand alone on their hexdocs page) are pinned by tests that fail
  when the benchmark figures, the handler event list, or the `use MqttX`
  callback set diverge.
- New regression suites: malformed-packet decoding, Ranch adapter integration
  (previously zero Ranch tests), inbound topic aliases, resubscribe on
  reconnect, in-flight resend/discard, the non-blocking connect FSM,
  declared-length enforcement, SUBACK/UNSUBACK validation, encode length
  guards, multi-filter shared subscriptions, session takeover, session-expiry
  cancellation, DISCONNECT expiry revision, `retain_handling: 1`, the outbound
  Receive Maximum queue, and idle/handshake timeouts.
- Property-based codec tests: round-trips for PUBLISH/SUBSCRIBE/acks/CONNECT/
  properties/varints, plus "decode never raises" over arbitrary bytes and
  bit-flipped valid packets.
- Client unit tests use guaranteed-closed ephemeral ports instead of assuming
  nothing listens on `localhost:1883`.

## [0.10.0] - 2026-05-07

Spec-compliance and correctness sweep against MQTT 5.0 (OASIS), plus server/
client robustness fixes. EMQX interop suite (49 tests against a live broker)
remains 100% green. No changes to the function API surface, but note the
**behavioral/wire default change** below: the default `protocol_version`
flipped from 4 to 5, which is observable by brokers and dependents.

### Changed (potentially breaking at the wire level — stricter spec compliance)

- **Default `protocol_version` is now `5`** (was `4`). Library is
  marketed "MQTT 5.0" and v5 features (topic aliases, AUTH, properties,
  reason codes) were silently dropped under the v3.1.1 default.
  `MqttX.Client.connect(protocol_version: 4)` to opt in to v3.1.1.
- **Server now rejects unsupported protocol versions** with CONNACK
  `0x84` (v5) / `0x01` (v3.x). Default allowlist `[3, 4, 5]` configurable
  via `:supported_versions` in `transport_opts`.

### Fixed (codec — `MqttX.Packet.Codec` / `MqttX.Packet.Properties`)

- PUBLISH with QoS=3 rejected as Malformed Packet (§3.3.1.2)
- PUBLISH with DUP=1 + QoS=0 rejected (§3.3.1.1)
- CONNECT reserved bit must be 0 (§3.1.2.3); non-zero fixed-header flags rejected (§3.1.1)
- Will Flag=0 with non-zero Will QoS or Will Retain rejected (§3.1.2.6/7)
- Will QoS=3 rejected (§3.1.2.6)
- v3.x username flag=0 with password flag=1 rejected (§3.1.2.9)
- Empty SUBSCRIBE / UNSUBSCRIBE payload rejected as Protocol Error (§3.8.3 / §3.10.3)
- Subscription Options reserved bits non-zero, QoS=3, RH=3 rejected (§3.8.3.1)
- DISCONNECT and AUTH 1-byte forms (reason code only, no property length) accepted per §3.14.2.2.1 / §3.15.2.2.1
- UTF-8 strings now reject U+0000 (null) and U+D800–U+DFFF (surrogates) per §1.5.4
- Malformed CONNECT no longer crashes the codec with `MatchError`; surfaces `:malformed_packet`
- Invalid SUBACK/UNSUBACK reason bytes return `:malformed_packet` instead of crashing
- **Properties** — duplicate non-User-Property properties rejected as Protocol Error (§2.2.2.2)
- Property value-0 rejection: Subscription Identifier (§3.8.2.1.2), Receive Maximum (§3.1.2.11.3), Maximum Packet Size (§3.1.2.11.4)
- Boolean properties (Payload Format Indicator, Request Problem Information, Retain Available, etc.) reject non-0/1 byte values
- Maximum QoS rejects values > 2
- User-Property accumulation switched from O(n²) `++ [val]` to prepend + reverse-once
- Subscription-Identifier list switched from O(n²) `++ [val]` to prepend + reverse-once

### Fixed (topic — `MqttX.Topic`)

- `+`/`#` filters at the first level no longer match `$SYS/...`-style topics (§4.7.2)
- Topic length capped at 65535 bytes (§1.5.4)
- Shared subscription `$share/<group>/...` rejects `+` or `#` in ShareName (§4.8.2)
- `flatten/1` switched from O(n²) binary concat to iolist + `Enum.intersperse`

### Fixed (server — `MqttX.Transport.Handler` / `MqttX.Server.Router` / `MqttX.Server.RateLimiter`)

- **Outgoing QoS 1 retransmission on the server** (§4.4). Outbound QoS 1
  PUBLISHes are now tracked in `pending_qos1_tx`; the existing periodic retry
  timer re-sends with `DUP=true` after `qos2_retry_interval` ms, dropping
  after `qos2_max_retries` attempts. PUBACK arrival clears the entry.
  Previously QoS 1 outbound was fire-and-forget — a lost PUBACK silently
  dropped the message.
- **Receive Maximum applies to QoS 1 inbound** as well as QoS 2 (§3.1.2.11.3).
  Previously the limit was only checked for QoS 2; a client could fill the
  flow-control window with un-PUBCOMP'd QoS 2 messages and then push QoS 1
  publishes through unbounded. The handler now responds to a QoS 1 PUBLISH
  exceeding the limit with `PUBACK` reason `0x93` (Receive Maximum exceeded).
  QoS 2 excess continues to receive `PUBREC 0x93` (spec permits either
  per-message ack or DISCONNECT).

- **Critical:** retained-publish packet IDs now come from `next_packet_id` instead of `:rand.uniform/1` — was colliding with the QoS sequence allocator and breaking ack matching
- Will message published exactly once on keepalive timeout / `handle_close` / `handle_error` (was double-publishing through two paths)
- DISCONNECT reason code 0x04 publishes the Will; other reason codes suppress it (§3.14.4) — previously the reason code was ignored
- Empty topic with un-mapped Topic Alias triggers DISCONNECT 0x94 (§3.3.4) — previously dispatched an empty-topic PUBLISH to the user handler
- Outbound oversize-drop rolls back the packet_id allocation (was leaking)
- Duplicate PUBREC after PUBREL no longer re-sends PUBREL (§4.3.3 fig 4.4)
- AUTH-before-CONNECT now sends DISCONNECT 0x82 instead of leaving the handler in a broken state (CONNACK with `protocol_version: nil`)
- Will Delay Interval timers (§3.1.3.2.2) now owned by a supervised `MqttX.Server.WillDelay` GenServer under the application supervisor; cancelled on same-`client_id` reconnect
- Rate-limiter ETS table now created with `read_concurrency: true`

### Fixed (client — `MqttX.Client.Connection`)

- **Critical:** retry-loop reducer arity bug fixed — was crashing with
  `MatchError` once both `{:rx, _}` and `{:tx, _}` `pending_acks` entries
  coexisted on the same connection
- `keepalive == 0` correctly disables the keepalive timer (was scheduling a
  zero-millisecond tight loop)
- **PINGRESP timeout**: client now arms a deadline at `keepalive*1500ms` on
  every PINGREQ; if PINGRESP doesn't arrive, the socket is torn down and
  reconnect is scheduled. Half-dead brokers no longer require TCP teardown to
  detect.
- `session_present` from CONNACK now surfaced to the handler in the
  `:connected` event; warns on MQTT-3.2.2-2 violation (`clean_session=true`
  but `session_present=true`)
- Server-initiated DISCONNECT now closes the socket immediately and schedules
  reconnect (was waiting for `:tcp_closed` to land separately)
- AUTH continuation in `wait_for_connack` re-arms `set_socket_active/1` so
  multi-step AUTH doesn't hang after the first packet
- AUTH packet property names corrected: `:auth_method` / `:auth_data` →
  `:authentication_method` / `:authentication_data`
- `next_packet_id` skips IDs currently in `pending_acks` (§2.2.1)
- `schedule_reconnect` cancels any existing reconnect timer (no more stacked
  timers when several disconnect events fire)
- `set_socket_active` guards against `nil` socket (server-disconnect race)
- Pending SUBACK/UNSUBACK callers monitored via `Process.monitor`; entry
  dropped on `:DOWN` (was leaking after `GenServer.call` timeouts)

### Fixed (WebSocket client — `MqttX.Client.WebSocket`)

- `Sec-WebSocket-Accept` now validated as `Base64(SHA1(client_key + magic GUID))`
  per RFC 6455 §4.1; status line strictly matched as `HTTP/1.x 101 …`
- `Sec-WebSocket-Protocol` echo checked (warn-only on missing — common with
  MQTT brokers that nonetheless speak it correctly)
- FIN-bit fragmentation: opaque `frag_state` threaded across `decode_frames/2`
  calls so multi-frame messages split across TCP reads reassemble correctly
- Frame masking switched from byte-by-byte recursion to `:crypto.exor/2`
  against a pre-padded mask buffer (orders-of-magnitude faster on large
  payloads)

### Added

- `MqttX.Session.ETSOwner` — a long-lived owner of the default
  `:mqttx_sessions` ETS table under the application supervisor. Previously
  the table was owned by whichever client first called
  `MqttX.Session.ETSStore.init/1`, so all sessions were lost when that
  process exited. The table is now created with `read_concurrency: true,
  write_concurrency: true`.
- `MqttX.Server.WillDelay` — supervised GenServer that owns Will Delay
  Interval timers across connection lifecycles, with per-`client_id`
  cancellation.
- `:supported_versions` server transport option (default `[3, 4, 5]`).

### Documentation

- `AGENTS.md` — usage guide for AI coding assistants integrating MqttX into
  projects: mental model (client vs broker), transport selection, idiomatic
  patterns (receive-on-client, broker↔PubSub bridge, persistent sessions,
  custom auth), and a curated list of mistakes commonly made (publishing
  wildcards, confusing `handle_publish` with `handle_mqtt_event`, random
  `client_id` per connect, default-to-QoS-2, `$SYS` exclusion). Shipped in
  the hex package and rendered on hexdocs.
- `CONTRIBUTING.md` — repo orientation for contributors: layout, test
  commands, known test-environment couplings, and the deferred TODO carried
  over from the v0.9.0 spec sweep. `CLAUDE.md` is now a symlink to
  `AGENTS.md` for tool compatibility.
- README "Common Patterns" section with worked examples for receiving
  messages on the client (`handle_mqtt_event/3`), broadcasting from the
  server via `handle_info/2`, and resuming MQTT 5.0 sessions with
  `session_expiry_interval`.
- README "Common Pitfalls" section covering session-store / `clean_session`
  interaction, server keepalive override, max-packet-size enforcement,
  publish-vs-subscribe wildcard rules, and `$SYS` topic exclusion.

## [0.9.0] - 2026-03-30

### Added

- **Server keepalive override** (MQTT 5.0): Configurable `server_keep_alive` in `transport_opts` — server sends keepalive override in CONNACK and uses it for the keepalive timer when protocol version >= 5
- **`handle_connect/4` callback** (optional): New `handle_connect(client_id, credentials, connect_info, state)` callback that receives connection metadata (`protocol_version`, `keep_alive`) separately from credentials. Existing `handle_connect/3` continues to work unchanged — `handle_connect/4` takes precedence when defined

## [0.8.0] - 2026-03-11

### Added

- **Complete MQTT 5.0 Client Compliance**: Closed all remaining client-side spec gaps
  - **server_keep_alive**: Client applies server's keepalive override from CONNACK (§3.2.2.3.14)
  - **assigned_client_identifier**: Client adopts server-assigned client ID from CONNACK (§3.2.2.3.7)
  - **maximum_packet_size**: Client enforces server's maximum packet size from CONNACK; oversized outgoing packets return `{:error, :packet_too_large}` (§3.2.2.3.6)
  - **server_reference**: Client parses and logs server redirect on CONNACK rejection and server DISCONNECT (§3.2.2.3.18)
  - **Enhanced AUTH**: Client handles multi-step AUTH exchange during and after CONNECT via `handle_auth/3` callback (§4.12)
- **EMQX Cloud Interop**: 49 automated interop tests against EMQX Cloud broker
- **SUBACK Reason Code Checking**: `subscribe/3` now returns `{:ok, [granted_qos]}` or `{:error, {:subscription_refused, acks}}` based on actual SUBACK response
- **Outgoing Topic Aliases** (MQTT 5.0): Client automatically assigns and reuses topic aliases for repeated publish topics, reducing bandwidth
- **DISCONNECT with Reason Code**: `disconnect/2` accepts `:reason_code` and `:properties` options for MQTT 5.0 graceful disconnect
- **WebSocket Client Transport**: Connect to brokers over WebSocket with `transport: :ws` or `transport: :wss` (RFC 6455 binary framing)
- **Reason String Surfacing**: Server reason strings from SUBACK, UNSUBACK, PUBACK, DISCONNECT are logged automatically

### Fixed

- Formatting issues across multiple files (CI compliance)
- Dialyzer `callback_type_mismatch` in WebSocket transport `close/1` (now returns `:ok` per behaviour spec)
- WebSocket frame decoder byte-alignment bug in `decode_one_frame` (mask_bit extraction)

## [0.7.0] - 2026-03-05

### Added

- **Full MQTT 3.1/3.1.1/5.0 Compliance**: Closed all remaining spec compliance gaps
  - **Pre-CONNECT packet rejection**: Non-CONNECT/AUTH packets before CONNECT now trigger DISCONNECT 0x82 (Protocol Error) per spec
  - **Topic alias validation**: Incoming topic aliases are validated against `topic_alias_maximum`; out-of-range aliases trigger DISCONNECT 0x94
  - **MQTT 5.0 property forwarding**: Outgoing PUBLISH packets now forward properties (user_properties, content_type, correlation_data, etc.) from handler callbacks
  - **CONNACK capability properties**: Server advertises `retain_available`, `wildcard_subscription_available`, and `subscription_identifier_available` in CONNACK for MQTT 5.0 connections
  - **retain_handling support**: Subscription option `retain_handling: 2` suppresses retained message delivery on subscribe
  - **no_local support**: `Router.match/3` and `Router.match_and_advance/3` accept optional `publisher` parameter to filter out subscriptions with `no_local: true`
  - **Client server DISCONNECT handling**: Client now handles server-initiated DISCONNECT packets, notifying the handler with `{:server_disconnect, reason_code}`
- **QoS 2 Retransmission & DUP Handling** (Server): Periodic retry timer re-sends PUBREC/PUBLISH(dup)/PUBREL for stale in-flight QoS 2 messages; drops after configurable max retries. DUP incoming PUBLISH re-sends PUBREC without re-delivering.
- **Topic Aliases** (MQTT 5.0 Server): Incoming PUBLISH with `topic_alias` property resolved automatically. Server advertises `topic_alias_maximum` in CONNACK. Alias-only publishes (empty topic) look up stored mapping.
- **Flow Control / Receive Maximum** (MQTT 5.0 Server): Server enforces `receive_maximum` for incoming QoS 2 messages. Excess publishes receive PUBREC with reason code `0x93` (Receive Maximum exceeded). Server advertises `receive_maximum` in CONNACK.
- **Maximum Packet Size** (MQTT 5.0 Server): Configurable `max_packet_size` option. Oversized incoming packets trigger DISCONNECT with reason code `0x95` (Packet too large). Outgoing publishes exceeding client's `maximum_packet_size` are silently dropped. Server advertises `maximum_packet_size` in CONNACK when configured.
- **WebSocket Transport**: MQTT over WebSocket via Bandit, supporting all MQTT protocol features over `ws://` and `wss://` connections.
- **Mosquitto Validation Suite**: 104 automated tests against Mosquitto clients across TCP and WebSocket transports, covering all protocol versions and MQTT 5.0 features.
- **Handler tests**: 30+ new tests covering compliance features, QoS 2 full flow, DUP handling, retry timer, CONNACK properties, topic aliases, flow control, max packet size, and server-initiated DISCONNECT.

### Changed

- **Codec**: MQTT 5.0 PUBLISH with empty topic is now valid when `topic_alias` property is present (per MQTT 5.0 spec section 3.3.2.1)
- **QoS 2 pending entries**: `pending_qos2_rx` entries now include timestamps and retry counts; `pending_qos2_tx` entries are enriched maps with phase, packet, timestamp, and retry info
- **Router API**: `match/2` → `match/3` and `match_and_advance/2` → `match_and_advance/3` with optional `publisher` parameter (backward compatible, defaults to `nil`)

### Fixed

- Server PUBREL handler now correctly extracts packet/opts from both legacy 2-tuple and new 4-tuple `pending_qos2_rx` entries

## [0.6.1] - 2026-03-02

### Fixed

- Logo rendering on hexdocs.pm (use absolute URL for README image)
- CI: increased GenServer.stop timeout in client tests for slower runners
- CI: skip JSON payload tests on OTP < 27
- Removed accidentally committed mqttx-0.1.0 directory

## [0.6.0] - 2026-03-02

### Added

- **Connection Supervision**: `MqttX.Client.Supervisor` DynamicSupervisor for managed client connections
  - `MqttX.Client.connect_supervised/1` starts connections under the supervisor with automatic crash recovery
  - `MqttX.Client.list/0` lists all registered connections via `MqttX.ClientRegistry`
  - `MqttX.Client.whereis/1` looks up connections by client_id
  - Connections auto-register in `MqttX.ClientRegistry` on init
- **Rate Limiting**: Per-client connection and message rate limiting for MQTT servers
  - `MqttX.Server.RateLimiter` module with ETS-based atomic counters
  - Connection rate limiting (configurable max connections per interval)
  - Per-client message rate limiting (configurable max messages per client per interval)
  - MQTT 5.0 reason code `0x96` (message_rate_too_high) sent for rate-limited QoS 1+ publishes
  - Integrated into both ThousandIsland and Ranch transport adapters
  - Configured via `:rate_limit` option in `MqttX.Server.start_link/3`
- **Capacity Planning guide**: Device-per-vCPU sizing tables for IoT workloads (sleepy sensors through real-time streaming), instance sizing recommendations
- **Performance & Scaling guide**: Architecture decisions, trie router internals, VM/OS tuning, and deployment guidelines
- **Project Branding**: MqttX logo in README and hexdocs
- **EMQX interop test suite**: 49 tests against live EMQX broker covering MQTT 5.0 features
- **Server Keepalive Timeout**: Disconnects clients that stop sending packets within 1.5x `keep_alive` seconds (MQTT spec compliance)
  - Automatic timer start after CONNACK, reset on every received packet
  - Will message published on keepalive timeout (ungraceful disconnect)
- **Will Delay Interval** (MQTT 5.0): Delays will message publication by `will_delay_interval` seconds after ungraceful disconnect
  - `will_delay_interval: 0` (or MQTT 3.1.1) publishes immediately (backward compatible)
  - Will properties forwarded to handler
- **Session Expiry Timer** (MQTT 5.0): Fires `handle_session_expired/2` callback after `session_expiry_interval` seconds post-disconnect
  - `0` = expire immediately, `0xFFFFFFFF` = never expire
  - New optional `handle_session_expired/2` callback in `MqttX.Server` behaviour
- **Server-Initiated Disconnect**: Kick clients with MQTT 5.0 reason codes
  - `MqttX.Server.disconnect/3` sends DISCONNECT and closes connection
  - `{:disconnect, reason_code, state}` return type from `handle_publish`, `handle_subscribe`, `handle_unsubscribe`, `handle_info`
  - Ranch transport now properly forwards `handle_info` messages to handler (was silently dropping them)

### Changed

- **Trie-based Topic Router**: Replaced O(N) linear scan with a trie data structure for O(L+K) topic matching — independent of total subscription count. Same public API.
- **iodata Encoding**: Socket sends use `Codec.encode_iodata/2` in all transports, avoiding binary copies on every packet
- **Empty-buffer fast path**: Skips binary concatenation when the TCP buffer is empty (common case)
- **Cached callback dispatch**: `function_exported?` computed once at connection init, not per message
- **Direct inflight counter**: O(1) flow control check instead of scanning pending_acks
- **Retained message delivery**: Exact topic subscriptions use O(1) ETS lookup instead of full table scan

### Fixed

- **Handler state lost on callbacks**: `notify_handler` now correctly returns updated handler state (was silently discarding it)
- **Missing retries field in pending_acks**: QoS 1/2 pending_acks entries now include `retries: 0` (prevented retry tracking)
- **Session not saved on socket close**: Session data now persists on unexpected TCP close/error, not just clean disconnect
- **Queued messages not delivered on reconnect**: Buffer is now processed after CONNACK for persistent sessions
- **Protobuf codec crash on non-protobuf structs**: Now returns `{:error, {:protobuf_encode_error, _}}` instead of raising
- **Protobuf codec crash on unknown module**: Now returns `{:error, {:unknown_message_module, module}}` instead of raising
- Removed dead outgoing topic alias code (`topic_to_alias`, `next_alias`) that was never functional
- `MqttX.version/0` now returns correct version string
- Guides now included in hex.pm docs

## [0.5.0] - 2026-01-15

### Added

- **Telemetry Integration**: Comprehensive `:telemetry` events for observability
  - Client events: connect, disconnect, publish, subscribe, message
  - Server events: client_connect, client_disconnect, publish, subscribe
  - New `MqttX.Telemetry` module with helper functions
- **Shared Subscriptions** (MQTT 5.0): `$share/group/topic` pattern for load balancing
  - Round-robin distribution across group members
  - `Router.match_and_advance/2` for stateful distribution
  - Automatic group cleanup when last member leaves
- **Topic Alias** (MQTT 5.0): Bandwidth reduction for repeated topics
  - Client stores `topic_alias_maximum` from CONNACK
  - Resolves incoming topic aliases automatically
  - `alias_to_topic` map in connection state
- **Message Expiry** (MQTT 5.0): Respects `message_expiry_interval` property
  - Retained messages stored with timestamp
  - Expired messages skipped on delivery
  - Remaining expiry sent in delivered messages
- **Flow Control** (MQTT 5.0): Enforces `receive_maximum` for backpressure
  - Client tracks inflight QoS 1/2 message count
  - Returns `{:error, :flow_control}` when limit reached
  - Stores `receive_maximum` from CONNACK
- **Enhanced Auth** (MQTT 5.0): SASL-style authentication callback
  - New `handle_auth/3` callback in `MqttX.Server` behaviour
  - Default implementation returns error (not supported)
- **Request/Response** (MQTT 5.0): Helper for request/response pattern
  - `MqttX.Client.request/4` function
  - Passes `response_topic` and `correlation_data` properties
  - `:properties` option in `publish/4`

### Changed

- Transport adapters store retained messages with expiry metadata (5-tuple ETS format)
- Client connection state includes topic alias and receive_maximum fields

## [0.4.0] - 2026-01-15

### Added

- **TLS/SSL Client Support**: Optional TLS via `:transport` option (`:tcp` or `:ssl`)
  - `:ssl_opts` for SSL configuration (verify, cacerts, etc.)
  - Default port 8883 for SSL connections
- **QoS 2 Complete Flow**: Full PUBREC/PUBREL/PUBCOMP handshake implementation
  - Client tracks outgoing QoS 2 messages through all phases
  - Client handles incoming QoS 2 messages correctly
- **Message Inflight Tracking**: Timer-based retry for unacknowledged QoS 1/2 messages
  - Configurable `:retry_interval` option (default: 5000ms)
  - Automatic retry with `dup: true` flag
  - Max 3 retries before dropping message
- **Retained Messages**: Server stores and delivers retained messages
  - ETS-based storage per server instance
  - Delivered to new subscribers on SUBSCRIBE
  - Empty payload clears retained message
- **Will Message Delivery**: Server publishes will message on ungraceful disconnect
  - Stored from CONNECT packet
  - Published when connection closes without DISCONNECT
  - Supports retained will messages
- **Session Persistence**: Configurable session storage for `clean_session: false`
  - `MqttX.Session.Store` behaviour for custom implementations
  - `MqttX.Session.ETSStore` built-in in-memory store
  - Saves/restores subscriptions, pending messages, packet IDs

### Changed

- Client connection state now tracks subscriptions for session persistence
- Transport adapters create ETS tables for retained messages

## [0.3.0] - 2026-01-15

### Added

- MQTT vs WebSocket JSON performance comparison in README
- Comprehensive API reference documentation in README
- New test files for improved coverage:
  - `backoff_test.exs` - exponential backoff logic tests
  - `properties_test.exs` - MQTT 5.0 properties encode/decode tests
  - `client_test.exs` - client API tests
  - `server_test.exs` - server behaviour and callback tests
- MQTT 5.0 packet tests (AUTH, DISCONNECT with reason codes, properties)
- MQTT 3.1 packet tests
- Edge case tests (empty payload, large payload, max packet ID, unicode topics)

### Changed

- Updated ThousandIsland dependency to `~> 1.4` (was `~> 1.0`)
- Updated Ranch dependency to `~> 2.2` (was `~> 2.1`)
- Updated Protox dependency to `~> 2.0` (was `>= 1.7.0`)

### Fixed

- Formatting issues in `thousand_island.ex`
- Protobuf payload codec updated for Protox 2.0 API changes (encode returns 3-tuple)

## [0.2.0] - 2026-01-15

### Added

- `handle_info/2` callback for MqttX.Server to handle custom messages (e.g., PubSub)
- Support for outgoing PUBLISH via `{:publish, topic, payload, state}` return value
- Enables bidirectional communication (server can push messages to connected clients)

## [0.1.6] - 2026-01-15

### Changed

- Broadened protox dependency to support both 1.x and 2.x (`>= 1.7.0`)

## [0.1.5] - 2026-01-15

### Added

- GitHub Actions CI workflow (tests on Elixir 1.18-1.19, OTP 27-28, dialyzer)
- Roadmap section in README
- Username/password example in client documentation
- Changelog link on hex.pm package page
- Hex.pm, Docs, and CI badges to README

### Changed

- Documentation landing page now shows README instead of module docs

### Fixed

- JSON payload codec now conditionally compiles only on OTP 27+
- Code formatting issues
- Version test no longer hardcodes version string
- Dialyzer false positives for defensive pattern matching

## [0.1.1] - 2026-01-15

### Added

- GitHub Actions CI workflow (tests, formatting, dialyzer)
- Roadmap section in README
- Username/password example in client documentation
- Changelog link on hex.pm package page

### Fixed

- JSON codec description now correctly references built-in Erlang/OTP 27+ module

## [0.1.0] - 2026-01-14

### Added

- Initial release
- MQTT packet codec supporting MQTT 3.1, 3.1.1, and 5.0
- All 15 MQTT packet types
- MQTT 5.0 properties support
- ThousandIsland transport adapter
- Ranch transport adapter
- MQTT Server behaviour with handler callbacks
- Topic router with wildcard support (+, #)
- MQTT Client with automatic reconnection
- JSON payload codec (via built-in Erlang/OTP 27+ JSON module)
- Protobuf payload codec (via Protox)
- Raw binary payload codec
- Comprehensive test suite
