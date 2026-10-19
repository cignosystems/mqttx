# The TLS tests' private CA and `localhost` certificate are generated here,
# not committed (see MqttX.Test.TLSFixtures)
MqttX.Test.TLSFixtures.generate!(Path.expand("fixtures/tls", __DIR__))

# :load runs the end-to-end load test (test/mqttx/load_test.exs): `mix test --include load`
exclude = [:interop, :load]
exclude = if Code.ensure_loaded?(JSON), do: exclude, else: [:json | exclude]
ExUnit.start(exclude: exclude)
