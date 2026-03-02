exclude = [:interop]
exclude = if Code.ensure_loaded?(JSON), do: exclude, else: [:json | exclude]
ExUnit.start(exclude: exclude)
