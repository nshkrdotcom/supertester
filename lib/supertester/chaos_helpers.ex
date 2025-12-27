defmodule Supertester.ChaosHelpers do
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

  require Logger
  alias Supertester.ConcurrentHarness

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
      receive do
      after
        duration -> :ok
      end

      if Process.alive?(target) do
        Process.exit(target, reason)
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

    initial_supervisor_alive = Process.alive?(supervisor)

    # Run chaos loop
    stats =
      chaos_loop(supervisor, kill_rate, kill_interval_ms, kill_reason, end_time, %{
        killed: 0,
        restarted: 0
      })

    final_supervisor_alive = Process.alive?(supervisor)
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

  def simulate_resource_exhaustion(:process_limit, opts) do
    spawn_count = get_process_spawn_count(opts)
    spawned = spawn_resource_processes(spawn_count)
    cleanup_fn = build_process_cleanup_fn(spawned)
    {:ok, cleanup_fn}
  end

  def simulate_resource_exhaustion(:ets_tables, opts) do
    count = Keyword.get(opts, :count, 50)

    # Create ETS tables
    tables =
      for i <- 1..count do
        :ets.new(:"chaos_table_#{i}_#{:erlang.unique_integer([:positive])}", [:set, :public])
      end

    cleanup_fn = fn ->
      Enum.each(tables, fn table ->
        try do
          :ets.delete(table)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    {:ok, cleanup_fn}
  end

  def simulate_resource_exhaustion(:memory, opts) do
    # Allocate memory by creating large binaries
    size_mb = Keyword.get(opts, :size_mb, 10)
    bytes = size_mb * 1024 * 1024

    # Create a process to hold the memory
    pid =
      spawn(fn ->
        # Allocate memory
        _data = :binary.copy(<<0>>, bytes)

        receive do
          :stop -> :ok
        after
          # Auto-cleanup
          60_000 -> :ok
        end
      end)

    cleanup_fn = fn ->
      if Process.alive?(pid) do
        send(pid, :stop)
      end

      :ok
    end

    {:ok, cleanup_fn}
  end

  def simulate_resource_exhaustion(_resource, _opts) do
    {:error, :unsupported_resource}
  end

  # Private helpers for simulate_resource_exhaustion/2
  defp get_process_spawn_count(opts) do
    case Keyword.get(opts, :spawn_count) do
      nil ->
        percentage = Keyword.get(opts, :percentage, 0.05)
        trunc(10_000 * percentage)

      count ->
        count
    end
  end

  defp spawn_resource_processes(spawn_count) do
    for _ <- 1..spawn_count do
      spawn(&wait_for_stop_message/0)
    end
  end

  defp wait_for_stop_message do
    receive do
      :stop -> :ok
    after
      60_000 -> :ok
    end
  end

  defp build_process_cleanup_fn(spawned) do
    fn ->
      Enum.each(spawned, &stop_if_alive/1)
      :ok
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end

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

    # Wait for recovery
    start_time = System.monotonic_time(:millisecond)

    recovered = wait_for_recovery(recovery_fn, start_time, timeout)

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
    _timeout = Keyword.get(opts, :timeout, 30_000)
    start_time = System.monotonic_time(:millisecond)

    results =
      Enum.map(scenarios, fn scenario ->
        execute_chaos_scenario(target, scenario)
      end)

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
      children =
        try do
          Supervisor.which_children(supervisor)
        rescue
          _ -> []
        end

      # Kill random children based on kill_rate
      {killed_count, restarted_count} = kill_random_children(children, kill_rate, kill_reason)

      new_stats = %{
        killed: stats.killed + killed_count,
        restarted: stats.restarted + restarted_count
      }

      # Wait before next iteration
      receive do
      after
        kill_interval_ms -> :ok
      end

      # Continue loop
      chaos_loop(supervisor, kill_rate, kill_interval_ms, kill_reason, end_time, new_stats)
    end
  end

  defp kill_random_children(children, kill_rate, kill_reason) do
    kill_count = max(1, trunc(length(children) * kill_rate))

    # Randomly select children to kill
    to_kill =
      children
      |> Enum.shuffle()
      |> Enum.take(kill_count)

    killed =
      Enum.count(to_kill, fn {_id, pid, _type, _mods} ->
        if is_pid(pid) and Process.alive?(pid) do
          Process.exit(pid, kill_reason)
          true
        else
          false
        end
      end)

    # Count how many were restarted (simplified - just return killed count)
    {killed, killed}
  end

  defp wait_for_recovery(recovery_fn, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time > timeout do
      false
    else
      if recovery_fn.() do
        true
      else
        receive do
        after
          50 -> :ok
        end

        wait_for_recovery(recovery_fn, start_time, timeout)
      end
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
