defmodule EchoLab.PropertyHelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Supertester.PropertyHelpers

  property "genserver_operation_sequence normalizes operations" do
    operations = [:ping, {:cast, :pong}, {:call, :value}]
    generator = PropertyHelpers.genserver_operation_sequence(operations)

    check all(seq <- generator, max_runs: 3) do
      assert Enum.all?(seq, fn {tag, _} -> tag in [:call, :cast] end)
    end
  end

  property "concurrent_scenario produces configs" do
    generator =
      PropertyHelpers.concurrent_scenario(
        operations: [{:cast, :increment}, {:call, :value}],
        min_threads: 1,
        max_threads: 2,
        min_ops_per_thread: 1,
        max_ops_per_thread: 2
      )

    check all(cfg <- generator, max_runs: 2) do
      assert Map.has_key?(cfg, :thread_scripts)
      assert Map.has_key?(cfg, :timeout_ms)

      scenario = Supertester.ConcurrentHarness.from_property_config(EchoLab.TestableCounter, cfg)
      assert {:ok, _report} = Supertester.ConcurrentHarness.run(scenario)
    end
  end
end
