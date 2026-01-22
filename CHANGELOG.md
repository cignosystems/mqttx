# Changelog

All notable changes to this project will be documented in this file.

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
