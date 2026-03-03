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

  alias Supertester.{ChaosHelpers, PerformanceHelpers}
  alias Supertester.ConcurrentHarness.Runtime

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
      validate_setup!(scenario)
      validate_threads!(scenario)

      %__MODULE__{
        scenario
        | threads: normalize_threads(scenario),
          mailbox: normalize_mailbox(scenario.mailbox),
          chaos: normalize_chaos(scenario.chaos),
          performance_expectations: normalize_perf_expectations(scenario.performance_expectations)
      }
    end

    defp validate_setup!(%{setup: setup}) do
      unless is_function(setup, 0) do
        raise ArgumentError, "scenario setup must be a zero-arity function"
      end
    end

    defp validate_threads!(%{threads: []}) do
      raise ArgumentError, "scenario must define at least one thread script"
    end

    defp validate_threads!(_scenario), do: :ok

    defp normalize_threads(%{threads: threads, default_operation: default_op}) do
      Enum.map(threads, fn script ->
        script
        |> List.wrap()
        |> Enum.map(&Supertester.ConcurrentHarness.normalize_operation(&1, default_op))
      end)
    end

    defp normalize_mailbox(nil), do: nil
    defp normalize_mailbox(opts) when is_list(opts), do: opts
    defp normalize_mailbox(opts) when is_map(opts), do: Enum.into(opts, [])
    defp normalize_mailbox(_), do: raise(ArgumentError, "mailbox options must be a keyword list")

    defp normalize_chaos(nil), do: nil
    defp normalize_chaos(fun) when is_function(fun, 2), do: fun

    defp normalize_chaos(other) do
      raise ArgumentError, "chaos hook must be an arity-2 function, got #{inspect(other)}"
    end

    defp normalize_perf_expectations(nil), do: []
    defp normalize_perf_expectations(kv) when is_list(kv), do: kv

    defp normalize_perf_expectations(other) do
      raise ArgumentError,
            "performance expectations must be a keyword list, got #{inspect(other)}"
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
        nil -> fn -> module.start_link(server_opts) end
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
            fn -> module.start_link(Keyword.get(opts, :server_opts, [])) end,
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

  defp execute(%Scenario{} = scenario), do: Runtime.execute(scenario)
end
