defmodule Supertester.ConcurrentHarness.Runtime do
  @moduledoc false

  alias Supertester.{ConcurrentHarness, GenServerHelpers, PerformanceHelpers, Telemetry}
  alias Supertester.ConcurrentHarness.Scenario
  alias Supertester.Internal.ProcessLifecycle

  @spec execute(Scenario.t()) :: {:ok, map()} | {:error, term()}
  def execute(%Scenario{} = scenario) do
    scenario_id = System.unique_integer([:positive])
    metadata = Map.put(scenario.metadata, :scenario_id, scenario_id)
    start_ms = System.monotonic_time(:millisecond)
    Telemetry.scenario_start(metadata)

    result =
      case invoke_setup(scenario.setup) do
        {:ok, subject, setup_ctx} ->
          run_result = run_scenario(scenario, subject, setup_ctx, metadata, start_ms)

          cleanup_result =
            safe_cleanup(
              subject,
              setup_ctx,
              scenario.cleanup || (&ProcessLifecycle.default_cleanup/2)
            )

          merge_result_with_cleanup(run_result, cleanup_result)

        error ->
          error
      end

    emit_stop_event(result, start_ms, metadata)
    result
  end

  defp run_scenario(scenario, subject, setup_ctx, metadata, start_ms) do
    scenario_fun = fn ->
      run_core_scenario(scenario, subject, setup_ctx, metadata)
    end

    with {:ok, {{execution_result, mailbox_report}, performance_measurement}} <-
           run_with_performance_monitoring(scenario, metadata, fn ->
             run_with_optional_mailbox(scenario, subject, metadata, scenario_fun)
           end) do
      handle_execution_result(
        execution_result,
        scenario,
        metadata,
        subject,
        setup_ctx,
        mailbox_report,
        performance_measurement,
        start_ms
      )
    end
  end

  defp run_core_scenario(scenario, subject, setup_ctx, metadata) do
    chaos_ctx = %{metadata: metadata, setup_context: setup_ctx}
    chaos_state = maybe_start_chaos(scenario, subject, chaos_ctx, metadata)

    case execute_threads(scenario, subject) do
      {:ok, run_data} ->
        case await_chaos(chaos_state, scenario.timeout_ms, metadata) do
          {:ok, chaos_report} -> {:ok, run_data, chaos_report}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        cancel_chaos(chaos_state)
        {:error, reason}
    end
  end

  defp handle_execution_result(
         {:ok, run_data, chaos_report},
         scenario,
         metadata,
         subject,
         setup_ctx,
         mailbox_report,
         performance_measurement,
         start_ms
       ) do
    with :ok <-
           run_invariant(
             scenario,
             metadata,
             subject,
             setup_ctx,
             run_data,
             chaos_report,
             mailbox_report,
             performance_measurement
           ) do
      {:ok,
       build_report(
         metadata,
         setup_ctx,
         run_data,
         chaos_report,
         mailbox_report,
         performance_measurement,
         start_ms
       )}
    end
  end

  defp handle_execution_result(
         {:error, reason},
         _scenario,
         _metadata,
         _subject,
         _setup_ctx,
         _mailbox_report,
         _performance_measurement,
         _start_ms
       ),
       do: {:error, reason}

  defp invoke_setup(setup_fun) when is_function(setup_fun, 0) do
    case setup_fun.() do
      {:ok, pid} when is_pid(pid) -> {:ok, pid, %{}}
      {:ok, pid, ctx} when is_pid(pid) and is_map(ctx) -> {:ok, pid, ctx}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_setup_return, other}}
    end
  rescue
    error -> {:error, {:setup_failed, {error, __STACKTRACE__}}}
  end

  defp execute_threads(%Scenario{} = scenario, subject) do
    start_ms = System.monotonic_time(:millisecond)

    tasks =
      scenario.threads
      |> Enum.with_index()
      |> Enum.map(fn {script, idx} ->
        Task.async(fn -> run_thread(idx, script, scenario, subject, start_ms) end)
      end)

    results =
      tasks
      |> Task.yield_many(scenario.timeout_ms)
      |> Enum.map(fn
        {task, {:ok, value}} ->
          Task.shutdown(task, :brutal_kill)
          {:ok, value}

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        {task, {:exit, reason}} ->
          Task.shutdown(task, :brutal_kill)
          {:error, reason}
      end)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, {:thread_failure, Enum.find(results, &match?({:error, _}, &1))}}
    else
      thread_reports = Enum.map(results, fn {:ok, report} -> report end)

      duration_ms = System.monotonic_time(:millisecond) - start_ms
      total_operations = Enum.reduce(thread_reports, 0, fn r, acc -> acc + length(r.events) end)
      total_errors = Enum.reduce(thread_reports, 0, fn r, acc -> acc + r.errors end)

      {:ok,
       %{
         events: Enum.flat_map(thread_reports, & &1.events),
         threads: thread_reports,
         metrics: %{
           duration_ms: duration_ms,
           total_operations: total_operations,
           thread_count: length(thread_reports),
           operation_errors: total_errors
         }
       }}
    end
  end

  defp run_thread(thread_id, script, scenario, subject, scenario_start_ms) do
    {events, errors} =
      script
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {operation, step_idx}, {acc_events, acc_errors} ->
        started = System.monotonic_time(:millisecond)
        result = execute_operation(operation, subject, scenario)
        duration = System.monotonic_time(:millisecond) - started

        event = %{
          thread: thread_id,
          step: step_idx,
          operation: operation_descriptor(operation),
          result: result,
          duration_ms: duration,
          timestamp_ms: System.monotonic_time(:millisecond) - scenario_start_ms
        }

        new_errors =
          if match?({:error, _}, result), do: acc_errors + 1, else: acc_errors

        {[event | acc_events], new_errors}
      end)

    %{
      thread: thread_id,
      events: Enum.reverse(events),
      errors: errors
    }
  end

  defp execute_operation({:call, message}, subject, %Scenario{} = scenario) do
    GenServerHelpers.call_with_timeout(subject, message, scenario.call_timeout_ms)
  end

  defp execute_operation({:cast, message}, subject, %Scenario{} = scenario) do
    scenario
    |> cast_opts()
    |> then(fn opts ->
      case GenServerHelpers.cast_and_sync(
             subject,
             message,
             scenario.cast_sync_message,
             opts
           ) do
        :ok -> {:ok, :ok}
        other -> other
      end
    end)
  end

  defp execute_operation({:custom, fun}, subject, _scenario) when is_function(fun, 1) do
    {:ok, fun.(subject)}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp run_invariant(
         %Scenario{} = scenario,
         metadata,
         subject,
         setup_ctx,
         run_data,
         chaos_report,
         mailbox_report,
         performance_measurement
       ) do
    invariant = scenario.invariant || (&ConcurrentHarness.default_invariant/2)

    ctx =
      setup_ctx
      |> Map.put(:events, run_data.events)
      |> Map.put(:threads, run_data.threads)
      |> Map.put(:metrics, run_data.metrics)
      |> Map.put(:metadata, metadata)
      |> Map.put(:chaos, chaos_report)
      |> Map.put(:mailbox, mailbox_report)
      |> Map.put(:performance, performance_measurement)

    case invariant.(subject, ctx) do
      false -> {:error, {:invariant_failed, :returned_false}}
      {:error, reason} -> {:error, {:invariant_failed, reason}}
      _ -> :ok
    end
  rescue
    error -> {:error, {:invariant_failed, {error, __STACKTRACE__}}}
  end

  defp cast_opts(%Scenario{} = scenario) do
    [timeout: scenario.call_timeout_ms, strict?: scenario.strict_cast_sync?]
  end

  defp run_with_optional_mailbox(%Scenario{mailbox: nil}, _subject, _metadata, fun),
    do: {fun.(), nil}

  defp run_with_optional_mailbox(%Scenario{mailbox: opts}, subject, metadata, fun) do
    report = PerformanceHelpers.measure_mailbox_growth(subject, fun, opts)
    mailbox_report = Map.delete(report, :result)
    Telemetry.mailbox_sample(mailbox_report, metadata)
    {report.result, mailbox_report}
  end

  defp run_with_performance_monitoring(%Scenario{} = scenario, metadata, fun) do
    expectations = scenario.performance_expectations || []

    if expectations == [] do
      {:ok, {fun.(), nil}}
    else
      measurement = PerformanceHelpers.measure_operation(fun)

      try do
        PerformanceHelpers.assert_expectations(measurement, expectations)
        metrics_only = Map.take(measurement, [:time_us, :memory_bytes, :reductions])
        Telemetry.performance_event(metrics_only, metadata)
        {:ok, {measurement.result, metrics_only}}
      rescue
        error ->
          measurement_info = Map.take(measurement, [:time_us, :memory_bytes, :reductions])
          {:error, {:performance_failed, %{error: error, measurement: measurement_info}}}
      end
    end
  end

  defp maybe_start_chaos(%Scenario{chaos: nil}, _subject, _ctx, _metadata), do: nil

  defp maybe_start_chaos(%Scenario{chaos: chaos_fun}, subject, ctx, metadata) do
    Telemetry.chaos_event(:start, %{}, metadata)

    %{
      task: Task.async(fn -> chaos_fun.(subject, ctx) end),
      started_at: System.monotonic_time(:millisecond),
      metadata: metadata
    }
  end

  defp await_chaos(nil, _timeout, _metadata), do: {:ok, nil}

  defp await_chaos(
         %{task: task, started_at: started_at, metadata: metadata},
         timeout,
         _metadata_hint
       ) do
    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, value} ->
        Telemetry.chaos_event(:stop, %{duration_ms: duration_ms}, metadata)
        {:ok, %{result: value, duration_ms: duration_ms}}

      {:exit, reason} ->
        Telemetry.chaos_event(
          :stop,
          %{duration_ms: duration_ms},
          Map.put(metadata, :error, reason)
        )

        {:error, {:chaos_failed, reason}}

      nil ->
        Telemetry.chaos_event(
          :stop,
          %{duration_ms: duration_ms},
          Map.put(metadata, :error, :timeout)
        )

        {:error, {:chaos_failed, :timeout}}
    end
  end

  defp cancel_chaos(nil), do: :ok

  defp cancel_chaos(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp build_report(
         metadata,
         setup_ctx,
         run_data,
         chaos_report,
         mailbox_report,
         performance_measurement,
         start_ms
       ) do
    overall_duration_ms = System.monotonic_time(:millisecond) - start_ms

    %{
      events: run_data.events,
      threads: run_data.threads,
      metrics:
        run_data.metrics
        |> Map.put(:mailbox_observed?, not is_nil(mailbox_report))
        |> Map.put(:overall_duration_ms, overall_duration_ms),
      mailbox: mailbox_report,
      chaos: chaos_report,
      performance: performance_measurement,
      metadata: metadata,
      context: setup_ctx
    }
  end

  defp safe_cleanup(subject, setup_ctx, cleanup_fun) when is_function(cleanup_fun, 2) do
    cleanup_fun.(subject, setup_ctx)
    :ok
  rescue
    error -> {:error, {:cleanup_failed, {error, __STACKTRACE__}}}
  end

  defp merge_result_with_cleanup({:ok, report}, :ok), do: {:ok, report}
  defp merge_result_with_cleanup({:error, reason}, :ok), do: {:error, reason}

  defp merge_result_with_cleanup({:ok, report}, {:error, cleanup_reason}),
    do: {:error, {:cleanup_failed, cleanup_reason, report}}

  defp merge_result_with_cleanup({:error, reason}, {:error, cleanup_reason}),
    do: {:error, {:cleanup_failed, cleanup_reason, reason}}

  defp operation_descriptor({:call, msg}), do: {:call, msg}
  defp operation_descriptor({:cast, msg}), do: {:cast, msg}
  defp operation_descriptor({:custom, _fun}), do: :custom

  defp emit_stop_event(result, start_ms, metadata) do
    duration_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, _report} ->
        Telemetry.scenario_stop(%{duration_ms: duration_ms, status: :ok}, metadata)

      {:error, reason} ->
        Telemetry.scenario_stop(
          %{duration_ms: duration_ms, status: :error},
          Map.put(metadata, :error, reason)
        )
    end
  end
end
