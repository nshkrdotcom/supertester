defmodule EchoLab.ConcurrentHarnessTest do
  use ExUnit.Case, async: true

  alias Supertester.ConcurrentHarness

  alias EchoLab.{OneForOneSupervisor, TestableCounter}

  test "simple_genserver_scenario runs and reports" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        TestableCounter,
        [{:cast, :increment}, {:call, :value}],
        2,
        setup: fn -> TestableCounter.start_link(initial: 0) end,
        mailbox: [sampling_interval: 1],
        performance_expectations: [max_time_ms: 500],
        invariant: fn pid, ctx ->
          {:ok, %{count: count}} = Supertester.GenServerHelpers.get_server_state_safely(pid)
          assert count >= 0
          assert ctx.metrics.total_operations > 0
          :ok
        end
      )

    assert {:ok, report} = ConcurrentHarness.run(scenario)
    assert report.metrics.thread_count == 2
  end

  test "run_with_performance wraps scenario" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        TestableCounter,
        [{:call, :value}],
        1,
        setup: fn -> TestableCounter.start_link(initial: 1) end
      )

    assert {:ok, _report} =
             ConcurrentHarness.run_with_performance(scenario, max_time_ms: 500)
  end

  test "chaos hook helpers" do
    prefix = "harness_#{System.unique_integer([:positive])}"
    sup_name = EchoLab.Names.child_name(prefix, :supervisor)
    sup = start_supervised!({OneForOneSupervisor, name_prefix: prefix, name: sup_name})

    chaos = ConcurrentHarness.chaos_kill_children(kill_rate: 0.5, duration_ms: 10)
    _ = chaos.(sup, %{})

    noop_crash = ConcurrentHarness.chaos_inject_crash({:random, 0.0})
    _ = noop_crash.(sup, %{})
  end
end
