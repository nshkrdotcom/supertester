defmodule Supertester.ChaosHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.{ChaosHelpers, SupervisorHelpers, Assertions}
  alias Supertester.ConcurrentHarness

  defmodule ResilientWorker do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    @impl true
    def init(_opts) do
      {:ok, %{work_count: 0, crash_count: 0}}
    end

    @impl true
    def handle_call(:get_work_count, _from, state) do
      {:reply, state.work_count, state}
    end

    def handle_call(:get_crash_count, _from, state) do
      {:reply, state.crash_count, state}
    end

    @impl true
    def handle_cast(:do_work, state) do
      {:noreply, %{state | work_count: state.work_count + 1}}
    end

    @impl true
    def handle_info(:chaos_crash, state) do
      # Increment crash counter before crashing
      new_state = %{state | crash_count: state.crash_count + 1}
      # Simulate crash
      raise "chaos crash"
      {:noreply, new_state}
    end
  end

  defmodule ResilientSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    @impl true
    def init(opts) do
      worker_count = Keyword.get(opts, :workers, 3)

      children =
        for i <- 1..worker_count do
          %{
            id: :"worker_#{i}",
            start:
              {ResilientWorker, :start_link,
               [[name: :"worker_#{i}_#{:erlang.unique_integer([:positive])}"]]}
          }
        end

      Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
    end
  end

  defmodule TemporaryWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  defmodule TemporaryWorkerSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    @impl true
    def init(_opts) do
      children = [
        %{
          id: :temporary_worker,
          start:
            {TemporaryWorker, :start_link,
             [[name: :"temporary_worker_#{:erlang.unique_integer([:positive])}"]]},
          restart: :temporary
        }
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule FragileSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    @impl true
    def init(_opts) do
      children = [
        %{
          id: :fragile_worker,
          start:
            {ResilientWorker, :start_link,
             [[name: :"fragile_worker_#{:erlang.unique_integer([:positive])}"]]}
        }
      ]

      Supervisor.init(children, strategy: :one_for_one, max_restarts: 0, max_seconds: 5)
    end
  end

  defmodule DynamicTemporaryWorker do
    use GenServer

    def start_link(arg) do
      GenServer.start_link(__MODULE__, arg)
    end

    @impl true
    def init(arg), do: {:ok, arg}

    def child_spec(arg) do
      %{
        id: :dynamic_temporary_worker,
        start: {__MODULE__, :start_link, [arg]},
        restart: :temporary
      }
    end
  end

  describe "inject_crash/3" do
    test "injects a single crash into a process" do
      # Trap exits so we don't crash when worker crashes
      Process.flag(:trap_exit, true)

      {:ok, worker} =
        ResilientWorker.start_link(name: :"test_worker_#{:erlang.unique_integer([:positive])}")

      # Monitor the worker
      ref = Process.monitor(worker)

      # Inject immediate crash
      inject_crash(worker, :immediate)

      # Wait for crash
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1000

      # Restore trap_exit
      Process.flag(:trap_exit, false)
    end

    test "process can be supervised and restart after crash" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 1,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      [{:worker_1, worker_pid, :worker, _}] = Supervisor.which_children(supervisor)

      # Inject crash
      inject_crash(worker_pid, :immediate)

      # Wait for supervisor to restart
      wait_for_supervisor_stabilization(supervisor)

      # Verify new worker is running
      [{:worker_1, new_pid, :worker, _}] = Supervisor.which_children(supervisor)
      assert new_pid != worker_pid
      assert Process.alive?(new_pid)
    end

    test "delayed crash injects crash after duration" do
      Process.flag(:trap_exit, true)

      {:ok, worker} =
        ResilientWorker.start_link(name: :"test_worker_#{:erlang.unique_integer([:positive])}")

      ref = Process.monitor(worker)

      # Inject crash after 50ms
      inject_crash(worker, {:after_ms, 50})

      # Should still be alive immediately
      assert Process.alive?(worker)

      # Should crash after delay
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 200

      Process.flag(:trap_exit, false)
    end
  end

  describe "chaos_kill_children/3" do
    test "kills specified percentage of children" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 5,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      initial_children = Supervisor.which_children(supervisor)
      _initial_pids = Enum.map(initial_children, fn {_id, pid, _type, _mods} -> pid end)

      # Kill 60% of children (should kill 3 out of 5)
      report = chaos_kill_children(supervisor, kill_rate: 0.6, duration_ms: 100)

      # Wait for stabilization
      wait_for_supervisor_stabilization(supervisor)

      # Check report
      assert report.killed >= 2
      assert report.killed <= 4
      assert report.supervisor_crashed == false

      # Verify supervisor recovered
      assert Process.alive?(supervisor)
      new_children = Supervisor.which_children(supervisor)
      assert length(new_children) == 5
    end

    test "kill_rate 0.0 does not kill or restart any children" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 3,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      initial_children =
        Supervisor.which_children(supervisor)
        |> Enum.map(fn {id, pid, _type, _mods} -> {id, pid} end)
        |> Enum.sort()

      report =
        chaos_kill_children(supervisor, kill_rate: 0.0, duration_ms: 80, kill_interval_ms: 20)

      :ok = wait_for_supervisor_stabilization(supervisor)

      final_children =
        Supervisor.which_children(supervisor)
        |> Enum.map(fn {id, pid, _type, _mods} -> {id, pid} end)
        |> Enum.sort()

      assert report.killed == 0
      assert report.restarted == 0
      assert initial_children == final_children
    end

    test "supervisor survives chaos" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 3,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      report =
        chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 200, kill_interval_ms: 50)

      # Supervisor should be alive
      assert Process.alive?(supervisor)
      assert report.supervisor_crashed == false

      # All children should be restarted
      wait_for_supervisor_stabilization(supervisor)
      assert_all_children_alive(supervisor)
    end

    test "returns detailed report with kill statistics" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 4,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      report = chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 100)

      assert Map.has_key?(report, :killed)
      assert Map.has_key?(report, :restarted)
      assert Map.has_key?(report, :supervisor_crashed)
      assert is_integer(report.killed)
      assert is_integer(report.restarted)
      assert is_boolean(report.supervisor_crashed)
    end

    test "reports zero restarts for temporary children" do
      {:ok, supervisor} =
        TemporaryWorkerSupervisor.start_link(
          name: :"temp_sup_#{:erlang.unique_integer([:positive])}"
        )

      report =
        chaos_kill_children(supervisor, kill_rate: 1.0, duration_ms: 60, kill_interval_ms: 20)

      assert report.killed >= 1
      assert report.restarted == 0
      assert Supervisor.which_children(supervisor) == []
    end

    test "restarted accounting does not overcount for duplicate child IDs" do
      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

      {:ok, _pid_1} = DynamicSupervisor.start_child(supervisor, {DynamicTemporaryWorker, 1})
      {:ok, _pid_2} = DynamicSupervisor.start_child(supervisor, {DynamicTemporaryWorker, 2})

      report =
        chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 60, kill_interval_ms: 20)

      assert report.killed >= 1
      assert report.restarted == 0
    end

    test "accepts registered supervisor names" do
      global_name =
        {:global, {:chaos_named_supervisor, self(), System.unique_integer([:positive])}}

      {:ok, _supervisor} =
        ResilientSupervisor.start_link(
          workers: 2,
          name: global_name
        )

      report =
        chaos_kill_children(global_name, kill_rate: 0.0, duration_ms: 40, kill_interval_ms: 20)

      assert report.killed == 0
      assert report.restarted == 0
      assert report.supervisor_crashed == false
    end

    test "returns a report when the supervisor crashes during chaos" do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

      {:ok, supervisor} =
        FragileSupervisor.start_link(name: :"fragile_sup_#{:erlang.unique_integer([:positive])}")

      report =
        chaos_kill_children(supervisor, kill_rate: 1.0, duration_ms: 80, kill_interval_ms: 20)

      assert report.killed >= 1
      assert report.supervisor_crashed == true
      refute Process.alive?(supervisor)
    end
  end

  describe "simulate_resource_exhaustion/2" do
    @tag :slow
    test "exhausts process limit and returns cleanup function" do
      # Get current process count
      initial_count = length(Process.list())

      # Exhaust 5% of remaining capacity (safe amount)
      {:ok, cleanup} =
        simulate_resource_exhaustion(:process_limit, percentage: 0.05, spawn_count: 100)

      # Should have spawned processes
      new_count = length(Process.list())
      assert new_count > initial_count
      assert new_count >= initial_count + 50

      # Cleanup should remove spawned processes
      cleanup.()

      # Give processes time to clean up
      receive do
      after
        50 -> :ok
      end

      # Count should be back near initial (allow some variance)
      final_count = length(Process.list())
      assert abs(final_count - initial_count) < 100
    end

    @tag :slow
    test "ETS table exhaustion" do
      initial_tables = length(:ets.all())

      {:ok, cleanup} = simulate_resource_exhaustion(:ets_tables, count: 50)

      new_tables = length(:ets.all())
      assert new_tables >= initial_tables + 40

      cleanup.()

      receive do
      after
        50 -> :ok
      end

      final_tables = length(:ets.all())
      assert abs(final_tables - initial_tables) < 10
    end

    test "returns error for invalid resource type" do
      assert {:error, :unsupported_resource} =
               simulate_resource_exhaustion(:invalid_resource, percentage: 0.1)
    end

    test "spawn_count 0 does not spawn any resource processes" do
      spawned =
        capture_direct_spawns(fn ->
          {:ok, cleanup} = simulate_resource_exhaustion(:process_limit, spawn_count: 0)
          cleanup.()
        end)

      assert spawned == []
    end

    test "non-positive ETS counts do not create exhaustion tables" do
      {:ok, cleanup_zero} = simulate_resource_exhaustion(:ets_tables, count: 0)
      {:ok, cleanup_negative} = simulate_resource_exhaustion(:ets_tables, count: -2)

      tables_zero = captured_tables(cleanup_zero)
      tables_negative = captured_tables(cleanup_negative)

      cleanup_zero.()
      cleanup_negative.()

      assert tables_zero == []
      assert tables_negative == []
    end
  end

  describe "assert_chaos_resilient/3" do
    test "asserts system recovers from chaos" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 3,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      chaos_fn = fn ->
        chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 100)
      end

      recovery_fn = fn ->
        wait_for_supervisor_stabilization(supervisor)
        Process.alive?(supervisor) and get_active_child_count(supervisor) == 3
      end

      assert_chaos_resilient(supervisor, chaos_fn, recovery_fn, timeout: 2000)
    end

    test "raises if system doesn't recover" do
      Process.flag(:trap_exit, true)

      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 2,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      chaos_fn = fn ->
        # Extreme chaos - kill supervisor itself
        Process.exit(supervisor, :kill)
      end

      recovery_fn = fn ->
        Process.alive?(supervisor)
      end

      assert_raise RuntimeError, ~r/System failed to recover/, fn ->
        assert_chaos_resilient(supervisor, chaos_fn, recovery_fn, timeout: 500)
      end

      Process.flag(:trap_exit, false)
    end
  end

  describe "run_chaos_suite/3" do
    test "runs multiple chaos scenarios and reports results" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 3,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      scenarios = [
        %{type: :kill_children, kill_rate: 0.3, duration_ms: 100},
        %{type: :kill_children, kill_rate: 0.5, duration_ms: 100}
      ]

      report = run_chaos_suite(supervisor, scenarios, timeout: 5000)

      assert report.total_scenarios == 2
      assert report.passed >= 0
      assert report.failed >= 0
      assert report.passed + report.failed == report.total_scenarios
      assert report.duration_ms > 0
    end

    test "continues running scenarios even if one fails" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 2,
          name: :"test_sup_#{:erlang.unique_integer([:positive])}"
        )

      scenarios = [
        %{type: :kill_children, kill_rate: 0.3, duration_ms: 50},
        # This should fail
        %{type: :invalid_type},
        %{type: :kill_children, kill_rate: 0.3, duration_ms: 50}
      ]

      report = run_chaos_suite(supervisor, scenarios, timeout: 5000)

      assert report.total_scenarios == 3
      assert report.passed >= 1
      assert report.failed >= 1
    end

    test "supports concurrent harness scenarios for richer chaos coverage" do
      Process.flag(:trap_exit, true)

      {:ok, worker} =
        ResilientWorker.start_link(
          name: :"chaos_harness_worker_#{:erlang.unique_integer([:positive])}"
        )

      on_exit(fn ->
        Process.flag(:trap_exit, false)

        if Process.alive?(worker) do
          GenServer.stop(worker)
        end
      end)

      scenarios = [
        %{
          type: :concurrent,
          build: fn target ->
            ConcurrentHarness.simple_genserver_scenario(
              ResilientWorker,
              [{:cast, :do_work}, {:call, :get_work_count}],
              2,
              setup: fn -> {:ok, target, %{}} end,
              cleanup: fn _, _ -> :ok end,
              invariant: fn _, ctx ->
                assert ctx.metrics.total_operations > 0
                assert ctx.metadata.scenario_id
              end
            )
          end
        }
      ]

      report = run_chaos_suite(worker, scenarios, timeout: 1000)

      assert report.total_scenarios == 1
      assert report.failed == 0
      assert report.duration_ms >= 0

      # ensure harness operations actually ran
      assert GenServer.call(worker, :get_work_count) > 0
    end

    test "respects overall timeout and does not run the full suite" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 1,
          name: :"timeout_sup_#{:erlang.unique_integer([:positive])}"
        )

      scenarios = [
        %{type: :kill_children, kill_rate: 1.0, duration_ms: 200, kill_interval_ms: 50},
        %{type: :kill_children, kill_rate: 1.0, duration_ms: 200, kill_interval_ms: 50}
      ]

      start_ms = System.monotonic_time(:millisecond)
      report = run_chaos_suite(supervisor, scenarios, timeout: 120)
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      assert elapsed_ms < 300
      assert report.failed >= 1

      assert Enum.any?(report.failures, fn %{reason: reason} ->
               reason in [:timeout, :suite_timeout]
             end)
    end

    test "marks unexecuted scenarios as suite_timeout after a timed-out scenario" do
      {:ok, supervisor} =
        ResilientSupervisor.start_link(
          workers: 1,
          name: :"timeout_chain_sup_#{:erlang.unique_integer([:positive])}"
        )

      scenarios = [
        %{type: :kill_children, kill_rate: 1.0, duration_ms: 250, kill_interval_ms: 50},
        %{type: :invalid_type}
      ]

      report = run_chaos_suite(supervisor, scenarios, timeout: 100)

      assert report.total_scenarios == 2
      assert report.failed == 2

      assert Enum.any?(report.failures, fn %{reason: reason} -> reason == :timeout end)
      assert Enum.any?(report.failures, fn %{reason: reason} -> reason == :suite_timeout end)

      refute Enum.any?(report.failures, fn %{reason: reason} ->
               reason == :unknown_scenario_type
             end)
    end
  end

  defp capture_direct_spawns(fun) when is_function(fun, 0) do
    caller = self()
    :erlang.trace(caller, true, [:procs])

    try do
      fun.()
    after
      :erlang.trace(caller, false, [:procs])
    end

    drain_spawn_messages(caller, [])
    |> Enum.uniq()
  end

  defp drain_spawn_messages(caller, acc) do
    receive do
      {:trace, ^caller, :spawn, spawned_pid, _mfa} when is_pid(spawned_pid) ->
        drain_spawn_messages(caller, [spawned_pid | acc])

      {:trace, ^caller, :spawned, spawned_pid, _mfa} when is_pid(spawned_pid) ->
        drain_spawn_messages(caller, [spawned_pid | acc])

      {:trace, ^caller, _event, _arg} ->
        drain_spawn_messages(caller, acc)

      {:trace, ^caller, _event, _arg1, _arg2} ->
        drain_spawn_messages(caller, acc)

      {:trace, ^caller, _event, _arg1, _arg2, _arg3} ->
        drain_spawn_messages(caller, acc)
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp captured_tables(cleanup_fun) when is_function(cleanup_fun, 0) do
    {:env, env} = :erlang.fun_info(cleanup_fun, :env)
    Enum.find(env, [], &is_list/1)
  end
end
