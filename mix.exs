defmodule Supertester.MixProject do
  use Mix.Project

  def project do
    [
      app: :supertester,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Multi-repository test orchestration and execution framework for Elixir monorepo structures",
      package: package(),
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

  defp package do
    [
      files: ~w(lib mix.exs README.md),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/supertester"}
    ]
  end
end
