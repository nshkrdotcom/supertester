defmodule Supertester.MixProject do
  use Mix.Project

  @version "0.5.0"
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
      dialyzer: [
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
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
      {:stream_data, "~> 1.0"},
      {:telemetry, "~> 1.0"},
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
      files:
        ~w(lib assets guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md) ++
          ~w(
            examples/README.md
            examples/echo_lab/README.md
            examples/echo_lab/mix.exs
            examples/echo_lab/.formatter.exs
            examples/echo_lab/.gitignore
            examples/echo_lab/config
            examples/echo_lab/lib
            examples/echo_lab/test
          ),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Online documentation" => "https://hexdocs.pm/supertester",
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["nshkrdotcom"],
      exclude_patterns: [
        "priv/plts",
        ".DS_Store",
        "examples/**/_build",
        "examples/**/deps",
        "examples/**/mix.lock",
        "examples/**/.elixir_ls",
        "examples/**/.hex",
        "examples/**/.mix",
        "examples/**/.rebar3",
        "examples/**/erl_crash.dump"
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
      assets: %{"assets" => "assets"},
      logo: "assets/supertester-logo.svg",
      extras: [
        "README.md",
        "guides/DOCS_INDEX.md",
        "guides/MANUAL.md",
        "guides/QUICK_START.md",
        "guides/API_GUIDE.md",
        {"examples/README.md", filename: "examples"},
        {"examples/echo_lab/README.md", filename: "example_echo_lab"},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: [
          "README.md",
          "guides/DOCS_INDEX.md",
          "guides/MANUAL.md",
          "guides/QUICK_START.md",
          "guides/API_GUIDE.md"
        ],
        Examples: [
          "examples/README.md",
          "examples/echo_lab/README.md"
        ],
        "Release Notes": ["CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Core API": [
          Supertester,
          Supertester.ExUnitFoundation,
          Supertester.UnifiedTestFoundation,
          Supertester.TestableGenServer
        ],
        "Concurrency Harness": [
          Supertester.ConcurrentHarness,
          Supertester.PropertyHelpers,
          Supertester.MessageHarness
        ],
        "Telemetry & Diagnostics": [
          Supertester.Telemetry
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
