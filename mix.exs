defmodule Supertester.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/nshkrdotcom/supertester"

  def project do
    [
      app: :supertester,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Supertester",
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
      {:benchee, "~> 1.3", only: :test, runtime: false},
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
    Battle-hardened OTP testing toolkit with chaos engineering, performance testing,
    and zero-sleep synchronization patterns for building robust Elixir applications.
    """
  end

  defp package do
    [
      name: "supertester",
      description: description(),
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md MANUAL.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Online documentation" => "https://hexdocs.pm/supertester",
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["nshkrdotcom"],
      exclude_patterns: [
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Supertester",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: [
        "README.md",
        "MANUAL.md",
        "docs/QUICK_START.md",
        "docs/API_GUIDE.md",
        "CHANGELOG.md",
        "docs/technical-design-enhancement-20251007.md",
        "docs/implementation-status-final.md",
        "docs/RELEASE_0.2.0_SUMMARY.md"
      ],
      groups_for_extras: [
        Guides: ["README.md", "MANUAL.md", "docs/QUICK_START.md", "docs/API_GUIDE.md"],
        Design: [
          "docs/technical-design-enhancement-20251007.md",
          "docs/implementation-status-final.md"
        ],
        "Release Notes": ["CHANGELOG.md", "docs/RELEASE_0.2.0_SUMMARY.md"]
      ],
      groups_for_modules: [
        "Core API": [
          Supertester,
          Supertester.UnifiedTestFoundation,
          Supertester.TestableGenServer
        ],
        "OTP Testing": [
          Supertester.OTPHelpers,
          Supertester.GenServerHelpers,
          Supertester.SupervisorHelpers
        ],
        "Chaos Engineering": [
          Supertester.ChaosHelpers
        ],
        "Performance Testing": [
          Supertester.PerformanceHelpers
        ],
        Assertions: [
          Supertester.Assertions
        ]
      ]
    ]
  end
end
