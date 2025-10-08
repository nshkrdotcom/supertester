defmodule Supertester.ChaosHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.{ChaosHelpers, SupervisorHelpers, Assertions}

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
      assert abs(final_count - initial_count) < 20
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
  end
end
