defmodule EchoLab.ChaosHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.ChaosHelpers

  alias EchoLab.{OneForOneSupervisor, TestableCounter}

  test "inject_crash variants" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)

    inject_crash(pid, :immediate, reason: :boom)
    assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

    delayed =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    delayed_ref = Process.monitor(delayed)
    inject_crash(delayed, {:after_ms, 5}, reason: :delayed)
    assert_receive {:DOWN, ^delayed_ref, :process, ^delayed, :delayed}

    random =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    random_ref = Process.monitor(random)
    inject_crash(random, {:random, 1.0}, reason: :random)
    assert_receive {:DOWN, ^random_ref, :process, ^random, :random}
  end

  test "chaos_kill_children and assert_chaos_resilient" do
    prefix = "chaos_#{System.unique_integer([:positive])}"
    sup_name = EchoLab.Names.child_name(prefix, :supervisor)

    sup =
      start_supervised!({
        OneForOneSupervisor,
        name_prefix: prefix, name: sup_name, max_restarts: 50, max_seconds: 1
      })

    report = chaos_kill_children(sup, kill_rate: 0.2, duration_ms: 10, kill_interval_ms: 5)
    assert report.killed >= 1
    assert report.duration_ms > 0

    assert_chaos_resilient(
      sup,
      fn -> chaos_kill_children(sup, kill_rate: 0.2, duration_ms: 10, kill_interval_ms: 5) end,
      fn ->
        Supervisor.which_children(sup)
        |> Enum.all?(fn
          {_id, pid, _type, _mods} when is_pid(pid) -> Process.alive?(pid)
          _ -> false
        end)
      end,
      timeout: 1_000
    )
  end

  test "simulate_resource_exhaustion cleanup" do
    {:ok, cleanup} = simulate_resource_exhaustion(:process_limit, spawn_count: 5)
    cleanup.()

    {:ok, cleanup_ets} = simulate_resource_exhaustion(:ets_tables, count: 2)
    cleanup_ets.()

    {:ok, cleanup_mem} = simulate_resource_exhaustion(:memory, size_mb: 1)
    cleanup_mem.()

    assert {:error, :unsupported_resource} = simulate_resource_exhaustion(:unknown)
  end

  test "run_chaos_suite supports concurrent scenarios" do
    prefix = "suite_#{System.unique_integer([:positive])}"
    sup_name = EchoLab.Names.child_name(prefix, :supervisor)
    sup = start_supervised!({OneForOneSupervisor, name_prefix: prefix, name: sup_name})

    scenario =
      Supertester.ConcurrentHarness.simple_genserver_scenario(
        TestableCounter,
        [{:cast, :increment}, {:call, :value}],
        2,
        setup: fn -> TestableCounter.start_link(initial: 0) end
      )

    scenarios = [
      %{type: :kill_children, kill_rate: 0.5, duration_ms: 10},
      %{type: :concurrent, scenario: scenario}
    ]

    report = run_chaos_suite(sup, scenarios)
    assert report.total_scenarios == 2
    assert report.failed == 0
  end
end
