defmodule Supertester.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/superlearner"

  def project do
    [
      app: :supertester,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      preferred_cli_env: [
        "test.all": :test,
        "test.integration": :test,
        "test.unit": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.all": ["test --include integration"],
      "test.integration": ["test --only integration"],
      "test.unit": ["test --exclude integration"]
    ]
  end

  defp description do
    """
    Multi-repository test orchestration and execution framework for Elixir monorepo structures
    """
  end

  defp package do
    [
      name: "supertester",
      files: ~w(lib assets .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/supertester"
      },
      maintainers: ["NSHkr <ZeroTrust@NSHkr.com>"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Supertester",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      assets: %{"assets" => "assets"},
      logo: "assets/supertester-logo.svg",
      groups_for_modules: [
        Core: [
          Supertester,
          Supertester.UnifiedTestFoundation
        ],
        Helpers: [
          Supertester.OTPHelpers,
          Supertester.GenServerHelpers
        ],
        Utilities: [
          Supertester.Assertions
        ]
      ]
    ]
  end
end
