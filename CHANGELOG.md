# Changelog

All notable changes to this project will be documented in this file.

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
