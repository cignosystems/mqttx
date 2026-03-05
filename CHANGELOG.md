# Changelog

All notable changes to this project will be documented in this file.

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

- GitHub Actions CI workflow (tests on Elixir 1.17-1.19, OTP 27-28, dialyzer)
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
