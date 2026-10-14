# :load runs the end-to-end load test (test/mqttx/load_test.exs): `mix test --include load`
exclude = [:interop, :load]
exclude = if Code.ensure_loaded?(JSON), do: exclude, else: [:json | exclude]
ExUnit.start(exclude: exclude)
