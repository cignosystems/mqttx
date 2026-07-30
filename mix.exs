defmodule MqttX.MixProject do
  use Mix.Project

  @version "0.11.0"
  @source_url "https://github.com/cignosystems/mqttx"

  def project do
    [
      app: :mqttx,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      # Honest floor at today's measured level (71.4%); raise as the thin
      # spots (WillDelay, Payload.Protobuf, SimpleClient) gain tests.
      test_coverage: [summary: [threshold: 70]],
      # Include the optional transport deps in the PLT so dialyzer actually
      # checks the adapter call sites
      dialyzer: [
        plt_add_apps: [
          :thousand_island,
          :ranch,
          :bandit,
          :websock_adapter,
          :mix,
          :ex_unit
        ],
        flags: [:error_handling]
      ],
      name: "MqttX",
      description: "Fast, pure Elixir MQTT 5.0 — client, server, and codec in one package"
    ]
  end

  def application do
    [
      # :ssl/:public_key must be listed or TLS transports fail inside releases
      extra_applications: [:logger, :crypto, :ssl, :public_key],
      mod: {MqttX.Application, []}
    ]
  end

  defp deps do
    [
      # Telemetry for observability
      {:telemetry, "~> 1.4"},

      # Transport adapters (optional - user picks one or more)
      {:thousand_island, "~> 1.4", optional: true},
      {:ranch, "~> 2.2", optional: true},
      {:bandit, "~> 1.6", optional: true},
      {:websock_adapter, "~> 0.5 or ~> 0.6", optional: true},

      # Payload codecs (optional)
      {:protox, "~> 2.0", optional: true},

      # Dev/test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
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
      files: ~w(lib assets guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md AGENTS.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "MqttX",
      logo: "assets/mqttx.png",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/mqttx",
      source_url: @source_url,
      extras: [
        "README.md",
        "AGENTS.md",
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/why-mqtt-for-iot.md",
        "guides/client.md",
        "guides/server.md",
        "guides/codec.md",
        "guides/telemetry.md",
        "guides/performance.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/why-mqtt-for-iot.md",
          "guides/client.md",
          "guides/server.md",
          "guides/codec.md",
          "guides/telemetry.md",
          "guides/performance.md"
        ]
      ],
      # CHANGELOG references internal modules (@moduledoc false) by name to
      # describe behaviour changes — that's expected and shouldn't warn.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      before_closing_head_tag: &before_closing_head_tag/1
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <style>
      .sidebar-projectImage img { max-height: 80px; }
    </style>
    """
  end

  defp before_closing_head_tag(_), do: ""
end
