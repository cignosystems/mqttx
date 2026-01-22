defmodule MqttX.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/cignosystems/mqttx"

  def project do
    [
      app: :mqttx,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "MqttX",
      description: "Pure Elixir MQTT 3.1.1/5.0 library - codec, server, and client"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {MqttX.Application, []}
    ]
  end

  defp deps do
    [
      # Telemetry for observability
      {:telemetry, "~> 1.3"},

      # Transport adapters (optional - user picks one or both)
      {:thousand_island, "~> 1.4", optional: true},
      {:ranch, "~> 2.2", optional: true},

      # Payload codecs (optional)
      {:protox, "~> 2.0", optional: true},

      # Dev/test
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Cigno Systems"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/mqttx/changelog.html"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "MqttX",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/mqttx",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
