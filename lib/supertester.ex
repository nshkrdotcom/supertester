defmodule Supertester do
  @moduledoc """
  Supertester - Multi-repository test orchestration and execution framework.

  Provides centralized test management, execution, and reporting across
  multiple Elixir repositories in a monorepo structure.

  ## Core Modules

  - `Supertester.UnifiedTestFoundation` - Test isolation and foundation patterns
  - `Supertester.OTPHelpers` - OTP-compliant testing utilities
  - `Supertester.GenServerHelpers` - GenServer-specific test patterns
  - `Supertester.SupervisorHelpers` - Supervision tree testing utilities
  - `Supertester.MessageHelpers` - Message tracing and ETS management
  - `Supertester.PerformanceHelpers` - Benchmarking and load testing
  - `Supertester.ChaosHelpers` - Chaos engineering and resilience testing
  - `Supertester.DataGenerators` - Test data and scenario generation
  - `Supertester.Assertions` - Custom OTP-aware assertions

  ## Usage

  Add supertester as a test dependency in your mix.exs:

      def deps do
        [
          {:supertester, path: "../supertester", only: :test}
        ]
      end

  Then use the helpers in your tests:

      defmodule MyApp.MyModuleTest do
        use ExUnit.Case, async: true
        import Supertester.OTPHelpers
        import Supertester.Assertions

        describe "my functionality" do
          setup do
            setup_isolated_genserver(MyModule, "my_test")
          end

          test "my test", %{server: server} do
            assert_genserver_responsive(server)
          end
        end
      end
  """

  @doc """
  Returns the version of Supertester.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:supertester, :vsn) |> to_string()
  end
end
