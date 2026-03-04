defmodule Supertester.ChaosHelpers do
  alias Supertester.Internal.Chaos.{ResourceExhaustion, SuiteRunner}
  alias Supertester.Internal.{Poller, SupervisorIntrospection}

  @moduledoc """
  Chaos engineering toolkit for OTP resilience testing.

  Provides controlled fault injection to verify system fault tolerance,
  recovery mechanisms, and graceful degradation under adverse conditions.

  ## Key Features

  - Process crash injection
  - Random child killing in supervision trees
  - Resource exhaustion simulation
  - Comprehensive chaos scenario testing

  ## Usage

      import Supertester.ChaosHelpers

      test "system survives random crashes" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

        # Inject random crashes
        inject_crash(worker, {:random, 0.3})

        # Run workload
        perform_work(1000)

        # Verify system recovered
        assert_all_children_alive(supervisor)
      end
  """

  alias Supertester.ConcurrentHarness
  @scenario_timeout_marker :__supertester_scenario_timeout__

  @type crash_spec ::
          :immediate
          | {:after_ms, milliseconds :: pos_integer()}
          | {:random, probability :: float()}

  @type chaos_report :: %{
          killed: non_neg_integer(),
          restarted: non_neg_integer(),
          supervisor_crashed: boolean(),
          duration_ms: non_neg_integer()
        }

  @type chaos_suite_report :: %{
          total_scenarios: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          failures: [failure_report()],
          duration_ms: non_neg_integer()
        }

  @type failure_report :: %{
          scenario: map(),
          reason: term()
        }

  @doc """
  Injects controlled crashes into a process for resilience testing.

  ## Parameters

  - `target` - The process PID to crash
  - `crash_spec` - How to crash the process
  - `opts` - Options (`:reason` for crash reason, default: `:chaos_injection`)

  ## Crash Specifications

  - `:immediate` - Crash immediately
  - `{:after_ms, duration}` - Crash after duration milliseconds
  - `{:random, probability}` - Crash with given probability (0.0 to 1.0)

  ## Examples

      # Immediate crash
      inject_crash(worker_pid, :immediate)

      # Delayed crash
      inject_crash(worker_pid, {:after_ms, 100})

      # Random crash (30% probability)
      inject_crash(worker_pid, {:random, 0.3})
  """
  @spec inject_crash(pid(), crash_spec(), keyword()) :: :ok
  def inject_crash(target, crash_spec, opts \\ [])

  def inject_crash(target, :immediate, opts) when is_pid(target) do
    reason = Keyword.get(opts, :reason, :chaos_injection)
    Process.exit(target, reason)
    :ok
  end

  def inject_crash(target, {:after_ms, duration}, opts)
      when is_pid(target) and is_integer(duration) do
    reason = Keyword.get(opts, :reason, :chaos_injection)

    spawn(fn ->
      ref = Process.monitor(target)

      receive do
        {:DOWN, ^ref, :process, ^target, _reason} ->
          :ok
      after
        duration ->
          Process.demonitor(ref, [:flush])

          if Process.alive?(target) do
            Process.exit(target, reason)
          end
      end
    end)

    :ok
  end

  def inject_crash(target, {:random, probability}, opts)
      when is_pid(target) and is_float(probability) do
    if :rand.uniform() < probability do
      inject_crash(target, :immediate, opts)
    else
      :ok
    end
  end

  @doc """
  Randomly kills children in a supervision tree to test restart strategies.

  ## Options

  - `:kill_rate` - Percentage of children to kill (default: 0.3 = 30%)
  - `:duration_ms` - How long to run chaos (default: 5000)
  - `:kill_interval_ms` - Time between kills (default: 100)
  - `:kill_reason` - Reason for kills (default: :kill)

  ## Examples

      test "supervisor handles cascading failures" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

        report = chaos_kill_children(supervisor,
          kill_rate: 0.5,
          duration_ms: 3000,
          kill_interval_ms: 200
        )

        # Verify supervisor survived
        assert Process.alive?(supervisor)
        assert report.supervisor_crashed == false
      end
  """
  @spec chaos_kill_children(Supervisor.supervisor(), keyword()) :: chaos_report()
  def chaos_kill_children(supervisor, opts \\ []) do
    kill_rate = Keyword.get(opts, :kill_rate, 0.3)
    duration_ms = Keyword.get(opts, :duration_ms, 5000)
    kill_interval_ms = Keyword.get(opts, :kill_interval_ms, 100)
    kill_reason = Keyword.get(opts, :kill_reason, :kill)

    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration_ms

    initial_supervisor_alive =
      case SupervisorIntrospection.resolve_supervisor_pid(supervisor) do
        pid when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end

    # Run chaos loop
    stats =
      chaos_loop(supervisor, kill_rate, kill_interval_ms, kill_reason, end_time, %{
        killed: 0,
        restarted: 0
      })

    final_supervisor_alive =
      case SupervisorIntrospection.resolve_supervisor_pid(supervisor) do
        pid when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end

    duration = System.monotonic_time(:millisecond) - start_time

    %{
      killed: stats.killed,
      restarted: stats.restarted,
      supervisor_crashed: initial_supervisor_alive and not final_supervisor_alive,
      duration_ms: duration
    }
  end

  @doc """
  Simulates resource exhaustion scenarios.

  ## Options

  - `:percentage` - Percentage of limit to consume (default: 0.8 = 80%)
  - `:spawn_count` - Explicit number of processes/resources to spawn
  - `:count` - Number of resources for non-percentage resources

  ## Examples

      test "system handles process limit pressure" do
        {:ok, cleanup} = simulate_resource_exhaustion(:process_limit,
          percentage: 0.05,  # Use small percentage for tests
          spawn_count: 100
        )

        # Perform operations under pressure
        result = perform_critical_operation()

        # Cleanup
        cleanup.()

        # Verify graceful degradation
        assert result == :ok or match?({:error, _}, result)
      end
  """
  @spec simulate_resource_exhaustion(atom(), keyword()) ::
          {:ok, cleanup_fn :: (-> :ok)} | {:error, term()}
  def simulate_resource_exhaustion(resource, opts \\ [])

  def simulate_resource_exhaustion(resource, opts),
    do: ResourceExhaustion.simulate(resource, opts)

  @doc """
  Asserts system recovers from chaos within timeout.

  ## Parameters

  - `system` - The system PID (supervisor or process)
  - `chaos_fn` - Function that applies chaos
  - `recovery_fn` - Function that checks if system recovered (returns boolean)
  - `opts` - Options (`:timeout` in ms, default: 5000)

  ## Examples

      assert_chaos_resilient(supervisor,
        fn -> chaos_kill_children(supervisor, kill_rate: 0.5) end,
        fn -> all_children_alive?(supervisor) end,
        timeout: 10_000
      )
  """
  @spec assert_chaos_resilient(pid(), (-> any()), (-> boolean()), keyword()) :: :ok
  def assert_chaos_resilient(system, chaos_fn, recovery_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    # Apply chaos
    chaos_fn.()

    recovered = wait_for_recovery(recovery_fn, timeout)

    if recovered do
      :ok
    else
      raise """
      System failed to recover from chaos within #{timeout}ms.

      System: #{inspect(system)}
      System alive: #{Process.alive?(system)}
      """
    end
  end

  @doc """
  Runs a comprehensive chaos testing suite.

  ## Parameters

  - `target` - The target system (supervisor or process)
  - `scenarios` - List of chaos scenarios
  - `opts` - Options (`:timeout` for overall timeout)

  ## Examples

      scenarios = [
        %{type: :kill_children, kill_rate: 0.3, duration_ms: 1000},
        %{type: :kill_children, kill_rate: 0.5, duration_ms: 1000},
      ]

      report = run_chaos_suite(supervisor, scenarios, timeout: 30_000)

      assert report.passed == report.total_scenarios
      assert report.failed == 0
  """
  @spec run_chaos_suite(pid(), [map()], keyword()) :: chaos_suite_report()
  def run_chaos_suite(target, scenarios, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_time = System.monotonic_time(:millisecond)

    {completed_results, remaining_scenarios} =
      SuiteRunner.run(
        target,
        scenarios,
        timeout,
        &execute_chaos_scenario/2,
        @scenario_timeout_marker
      )

    timeout_results =
      Enum.map(remaining_scenarios, fn scenario ->
        {:error, {scenario, :suite_timeout}}
      end)

    results = completed_results ++ timeout_results

    passed = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)

    failures =
      results
      |> Enum.filter(fn {status, _} -> status == :error end)
      |> Enum.map(fn {_status, {scenario, reason}} ->
        %{scenario: scenario, reason: reason}
      end)

    duration = System.monotonic_time(:millisecond) - start_time

    %{
      total_scenarios: length(scenarios),
      passed: passed,
      failed: failed,
      failures: failures,
      duration_ms: duration
    }
  end

  # Private functions

  defp chaos_loop(supervisor, kill_rate, kill_interval_ms, kill_reason, end_time, stats) do
    current_time = System.monotonic_time(:millisecond)

    if current_time >= end_time do
      stats
    else
      # Get current children
      children = SupervisorIntrospection.safe_children(supervisor)

      # Kill random children based on kill_rate.
      {killed_count, killed_children} = kill_random_children(children, kill_rate, kill_reason)

      # Wait before next iteration to allow restart processing.
      receive do
      after
        kill_interval_ms -> :ok
      end

      restarted_count = count_restarted_children(supervisor, children, killed_children)

      new_stats = %{
        killed: stats.killed + killed_count,
        restarted: stats.restarted + restarted_count
      }

      # Continue loop
      chaos_loop(supervisor, kill_rate, kill_interval_ms, kill_reason, end_time, new_stats)
    end
  end

  defp kill_random_children(children, kill_rate, kill_reason) do
    kill_count =
      if children == [] or kill_rate <= 0 do
        0
      else
        min(length(children), max(1, trunc(length(children) * kill_rate)))
      end

    # Randomly select children to kill
    to_kill =
      children
      |> Enum.shuffle()
      |> Enum.take(kill_count)

    {killed, killed_children} =
      Enum.reduce(to_kill, {0, []}, fn {id, pid, _type, _mods}, {count, acc} ->
        if is_pid(pid) and Process.alive?(pid) do
          Process.exit(pid, kill_reason)
          {count + 1, [{id, pid} | acc]}
        else
          {count, acc}
        end
      end)

    {killed, Enum.reverse(killed_children)}
  end

  defp count_restarted_children(_supervisor, _initial_children, []), do: 0

  defp count_restarted_children(supervisor, initial_children, _killed_children) do
    current_children = SupervisorIntrospection.safe_children(supervisor)

    initial_by_id = SupervisorIntrospection.group_child_pids_by_id(initial_children)
    current_by_id = SupervisorIntrospection.group_child_pids_by_id(current_children)

    Enum.reduce(initial_by_id, 0, fn {id, initial_pids}, acc ->
      current_pids = Map.get(current_by_id, id, [])
      acc + SupervisorIntrospection.replacement_count(initial_pids, current_pids)
    end)
  end

  defp wait_for_recovery(recovery_fn, timeout) do
    probe = fn -> if recovery_fn.(), do: :ok, else: :retry end

    case Poller.until(probe, timeout, 50) do
      :ok -> true
      {:error, :timeout} -> false
      {:error, _reason} -> false
    end
  end

  defp execute_chaos_scenario(target, scenario) do
    case scenario.type do
      :kill_children ->
        chaos_kill_children(target, Map.to_list(Map.delete(scenario, :type)))
        {:ok, scenario}

      :concurrent ->
        run_concurrent_scenario(target, scenario)

      _unknown ->
        {:error, {scenario, :unknown_scenario_type}}
    end
  rescue
    error ->
      {:error, {scenario, error}}
  catch
    :exit, reason ->
      {:error, {scenario, reason}}
  end

  defp run_concurrent_scenario(target, scenario) do
    with {:ok, harness_input} <- build_harness_input(target, scenario),
         {:ok, report} <- ConcurrentHarness.run(harness_input) do
      {:ok, Map.put(scenario, :report, report)}
    else
      {:error, reason} -> {:error, {scenario, reason}}
    end
  end

  defp build_harness_input(_target, %{scenario: %ConcurrentHarness.Scenario{} = spec}),
    do: {:ok, spec}

  defp build_harness_input(_target, %{scenario: spec}) when is_map(spec) or is_list(spec),
    do: {:ok, spec}

  defp build_harness_input(target, %{build: fun}) when is_function(fun, 1) do
    {:ok, fun.(target)}
  rescue
    error -> {:error, {:scenario_builder_failed, error}}
  end

  defp build_harness_input(_target, _scenario), do: {:error, :missing_concurrent_scenario}
end
