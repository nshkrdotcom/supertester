defmodule Supertester.ConcurrentHarness do
  @moduledoc """
  Scenario-based concurrency harness for OTP processes.

  This module coordinates multi-threaded test scenarios against a target process
  (typically a GenServer) while keeping isolation, cleanup, chaos injection,
  performance validation, telemetry, and invariant checks in one place.

  High level usage:

      scenario =
        Supertester.ConcurrentHarness.simple_genserver_scenario(
          MyServer,
          [:increment, :decrement],
          5,
          chaos: Supertester.ConcurrentHarness.chaos_inject_crash(),
          performance_expectations: [max_time_ms: 100],
          invariant: fn server, _ctx ->
            assert {:ok, state} = Supertester.GenServerHelpers.get_server_state_safely(server)
            assert state.count >= 0
          end
        )

      assert {:ok, report} = Supertester.ConcurrentHarness.run(scenario)

  The returned report contains thread events, chaos + mailbox + performance
  diagnostics, and emits telemetry for start/stop/chaos/mailbox/perf events.
  """

  alias Supertester.{ChaosHelpers, GenServerHelpers, PerformanceHelpers, Telemetry}

  @type operation :: {:call, term()} | {:cast, term()} | {:custom, (pid() -> any())}
  @type thread_script :: [operation()]
  @type chaos_fun :: (pid(), map() -> any())

  defmodule Scenario do
    @moduledoc """
    Struct describing a prepared concurrent scenario.

    Exposed primarily for introspection of generated scenarios—most callers
    should rely on `Supertester.ConcurrentHarness` helpers instead of
    constructing this struct manually.
    """

    @enforce_keys [:setup, :threads]
    defstruct setup: nil,
              threads: [],
              timeout_ms: 5_000,
              invariant: &Supertester.ConcurrentHarness.default_invariant/2,
              cleanup: nil,
              metadata: %{},
              call_timeout_ms: 1_000,
              cast_sync_message: :__supertester_sync__,
              strict_cast_sync?: false,
              default_operation: :call,
              mailbox: nil,
              chaos: nil,
              performance_expectations: []

    @type t :: %__MODULE__{
            setup: (-> {:ok, pid()} | {:ok, pid(), map()} | {:error, term()}),
            threads: [[Supertester.ConcurrentHarness.operation()]],
            timeout_ms: pos_integer(),
            invariant: (pid(), map() -> any()),
            cleanup: (pid(), map() -> any()) | nil,
            metadata: map(),
            call_timeout_ms: pos_integer(),
            cast_sync_message: term(),
            strict_cast_sync?: boolean(),
            default_operation: :call | :cast,
            mailbox: keyword() | nil,
            chaos: Supertester.ConcurrentHarness.chaos_fun() | nil,
            performance_expectations: keyword()
          }

    @doc false
    def build(%__MODULE__{} = scenario), do: normalize(scenario)

    def build(attrs) when is_map(attrs) do
      attrs
      |> Map.take(struct_keys())
      |> then(&struct!(__MODULE__, &1))
      |> normalize()
    end

    def build(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> build()

    defp struct_keys do
      __MODULE__
      |> struct()
      |> Map.from_struct()
      |> Map.keys()
    end

    defp normalize(%__MODULE__{} = scenario) do
      unless is_function(scenario.setup, 0) do
        raise ArgumentError, "scenario setup must be a zero-arity function"
      end

      if scenario.threads == [] do
        raise ArgumentError, "scenario must define at least one thread script"
      end

      normalized_threads =
        scenario.threads
        |> Enum.map(fn script ->
          script
          |> List.wrap()
          |> Enum.map(
            &Supertester.ConcurrentHarness.normalize_operation(&1, scenario.default_operation)
          )
        end)

      mailbox_opts =
        case scenario.mailbox do
          nil -> nil
          opts when is_list(opts) -> opts
          opts when is_map(opts) -> Enum.into(opts, [])
          _ -> raise ArgumentError, "mailbox options must be a keyword list"
        end

      chaos_fun =
        case scenario.chaos do
          nil ->
            nil

          fun when is_function(fun, 2) ->
            fun

          other ->
            raise ArgumentError, "chaos hook must be an arity-2 function, got #{inspect(other)}"
        end

      performance_expectations =
        case scenario.performance_expectations do
          nil ->
            []

          kv when is_list(kv) ->
            kv

          other ->
            raise ArgumentError,
                  "performance expectations must be a keyword list, got #{inspect(other)}"
        end

      %__MODULE__{
        scenario
        | threads: normalized_threads,
          mailbox: mailbox_opts,
          chaos: chaos_fun,
          performance_expectations: performance_expectations
      }
    end
  end

  @type scenario :: Scenario.t() | map() | keyword()

  @doc """
  Runs a concurrent scenario and returns a diagnostic report.
  """
  @spec run(scenario()) :: {:ok, map()} | {:error, term()}
  def run(%Scenario{} = scenario), do: execute(scenario)
  def run(attrs) when is_map(attrs) or is_list(attrs), do: attrs |> Scenario.build() |> execute()

  @doc """
  Runs a scenario while enforcing additional performance bounds externally.
  """
  @spec run_with_performance(scenario(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_with_performance(scenario, expectations) do
    measurement =
      PerformanceHelpers.measure_operation(fn ->
        run(scenario)
      end)

    PerformanceHelpers.assert_expectations(measurement, expectations)
    measurement.result
  end

  @doc """
  Default invariant that simply returns :ok.
  """
  @spec default_invariant(pid(), map()) :: :ok
  def default_invariant(_pid, _ctx), do: :ok

  @doc """
  Builds a scenario for a GenServer module with repeated operation scripts.

  ## Options

  * `:server_opts` - options passed to `start_link/1`
  * `:default_operation` - `:call` or `:cast` for bare terms (default: `:call`)
  * `:call_timeout_ms` - timeout for `GenServer.call/3` (default: 1_000)
  * `:timeout_ms` - overall scenario timeout (default: 5_000)
  * `:invariant` - function of `fn pid, ctx -> term end`
  * `:cleanup` - custom cleanup callback
  * `:metadata` - map merged into report metadata
  * `:mailbox` - keyword list passed to mailbox monitoring
  * `:chaos` - function `(pid, ctx) -> any` injected while threads execute
  * `:performance_expectations` - keyword list forwarded to `assert_expectations/2`
  """
  @spec simple_genserver_scenario(module(), [term() | operation()], pos_integer(), keyword()) ::
          Scenario.t()
  def simple_genserver_scenario(module, operations, thread_count, opts \\ [])
      when is_atom(module) and thread_count > 0 do
    server_opts = Keyword.get(opts, :server_opts, [])
    default_operation = Keyword.get(opts, :default_operation, :call)

    setup_fun =
      case Keyword.get(opts, :setup) do
        fun when is_function(fun, 0) -> fun
        nil -> fn -> apply(module, :start_link, [server_opts]) end
      end

    cleanup_fun =
      case Keyword.get(opts, :cleanup) do
        fun when is_function(fun, 2) -> fun
        nil -> &default_cleanup/2
      end

    threads =
      for _ <- 1..thread_count do
        Enum.map(operations, &normalize_operation(&1, default_operation))
      end

    Scenario.build(%{
      setup: setup_fun,
      cleanup: cleanup_fun,
      threads: threads,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, 1_000),
      invariant: Keyword.get(opts, :invariant, &default_invariant/2),
      metadata:
        %{module: module, thread_count: thread_count}
        |> Map.merge(Keyword.get(opts, :metadata, %{})),
      mailbox: Keyword.get(opts, :mailbox),
      default_operation: default_operation,
      chaos: Keyword.get(opts, :chaos),
      performance_expectations: Keyword.get(opts, :performance_expectations, [])
    })
  end

  @doc """
  Converts a property helper configuration into a runnable scenario.
  """
  @spec from_property_config(module(), map(), keyword()) :: Scenario.t()
  def from_property_config(module, config, opts \\ []) do
    scenario_opts =
      %{
        setup:
          Map.get(config, :setup) || Keyword.get(opts, :setup) ||
            fn -> apply(module, :start_link, [Keyword.get(opts, :server_opts, [])]) end,
        cleanup: Map.get(config, :cleanup) || Keyword.get(opts, :cleanup) || (&default_cleanup/2),
        threads: Map.fetch!(config, :thread_scripts),
        timeout_ms: Map.get(config, :timeout_ms, Keyword.get(opts, :timeout_ms, 5_000)),
        call_timeout_ms:
          Map.get(config, :call_timeout_ms, Keyword.get(opts, :call_timeout_ms, 1_000)),
        invariant:
          Map.get(config, :invariant) ||
            Keyword.get(opts, :invariant, &default_invariant/2),
        metadata:
          %{module: module}
          |> Map.merge(Map.get(config, :metadata, %{}))
          |> Map.merge(Keyword.get(opts, :metadata, %{})),
        mailbox: Map.get(config, :mailbox) || Keyword.get(opts, :mailbox),
        default_operation:
          Map.get(config, :default_operation, Keyword.get(opts, :default_operation, :call)),
        chaos: Map.get(config, :chaos) || Keyword.get(opts, :chaos),
        performance_expectations:
          Map.get(config, :performance_expectations) ||
            Keyword.get(opts, :performance_expectations, [])
      }

    Scenario.build(scenario_opts)
  end

  @doc """
  Chaos hook helper that kills supervisor children while the scenario runs.
  """
  @spec chaos_kill_children(keyword()) :: chaos_fun()
  def chaos_kill_children(opts \\ []) do
    fn subject, _ctx -> ChaosHelpers.chaos_kill_children(subject, opts) end
  end

  @doc """
  Chaos hook helper that injects a crash into the primary subject.
  """
  @spec chaos_inject_crash(ChaosHelpers.crash_spec(), keyword()) :: chaos_fun()
  def chaos_inject_crash(spec \\ :immediate, opts \\ []) do
    fn subject, _ctx -> ChaosHelpers.inject_crash(subject, spec, opts) end
  end

  @doc false
  def normalize_operation({:call, _msg} = op, _default), do: op
  def normalize_operation({:cast, _msg} = op, _default), do: op
  def normalize_operation({:custom, fun}, _default) when is_function(fun, 1), do: {:custom, fun}
  def normalize_operation(fun, _default) when is_function(fun, 1), do: {:custom, fun}

  def normalize_operation(term, default) when default in [:call, :cast] do
    {default, term}
  end

  def normalize_operation(term, _default) do
    raise ArgumentError, "unsupported operation #{inspect(term)}"
  end

  defp execute(%Scenario{} = scenario) do
    scenario_id = System.unique_integer([:positive])
    metadata = Map.put(scenario.metadata, :scenario_id, scenario_id)
    start_ms = System.monotonic_time(:millisecond)
    Telemetry.scenario_start(metadata)

    result =
      case invoke_setup(scenario.setup) do
        {:ok, subject, setup_ctx} ->
          run_result = run_scenario(scenario, subject, setup_ctx, metadata, start_ms)

          cleanup_result =
            safe_cleanup(subject, setup_ctx, scenario.cleanup || (&default_cleanup/2))

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
    invariant = scenario.invariant || (&default_invariant/2)

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

  defp default_cleanup(subject, _ctx) do
    if is_pid(subject) and Process.alive?(subject) do
      try do
        GenServer.stop(subject)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
