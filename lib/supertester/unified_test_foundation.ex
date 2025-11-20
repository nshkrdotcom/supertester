defmodule Supertester.UnifiedTestFoundation do
  alias Supertester.{Env, IsolationContext}

  @moduledoc """
  Isolation runtime for OTP-heavy tests.

  This module configures and maintains isolation contexts that can be plugged into any
  test harness. Use `Supertester.ExUnitFoundation` for the ready-made ExUnit adapter, or
  call the functions in this module directly from custom harnesses.

  ## Isolation Modes

  - `:basic` - Basic isolation with unique naming
  - `:registry` - Registry-based process isolation
  - `:full_isolation` - Complete process and ETS isolation
  - `:contamination_detection` - Isolation with contamination detection

  ## Usage with ExUnit

      defmodule MyApp.MyModuleTest do
        use Supertester.ExUnitFoundation, isolation: :full_isolation

        test "my test", context do
          # Test runs with full isolation
        end
      end

  ## Usage with custom harnesses

      :ok = Supertester.UnifiedTestFoundation.setup_isolation(:full_isolation, context)
  """

  @doc """
  Deprecated macro maintained for backwards compatibility.
  """
  defmacro __using__(opts) do
    IO.warn(
      "Supertester.UnifiedTestFoundation now only manages isolation. For ExUnit integration, use Supertester.ExUnitFoundation.",
      Macro.Env.stacktrace(__CALLER__)
    )

    quote do
      import Supertester.UnifiedTestFoundation
      use Supertester.ExUnitFoundation, unquote(opts)
    end
  end

  @doc """
  Sets up test isolation based on the specified isolation type.
  """
  @spec setup_isolation(atom(), map()) :: {:ok, map()}
  def setup_isolation(isolation_type, context) do
    case isolation_type do
      :basic ->
        setup_basic_isolation(context)

      :registry ->
        setup_registry_isolation(context)

      :full_isolation ->
        setup_full_isolation(context)

      :contamination_detection ->
        setup_contamination_detection(context)
    end
  end

  @doc """
  Fetches the isolation context stored in the current process.
  """
  @spec fetch_isolation_context() :: IsolationContext.t() | nil
  def fetch_isolation_context do
    Process.get(:isolation_context)
  end

  @doc """
  Stores the isolation context in the current process.
  """
  @spec put_isolation_context(IsolationContext.t() | nil) :: IsolationContext.t() | nil
  def put_isolation_context(context) do
    Process.put(:isolation_context, context)
    context
  end

  @doc """
  Adds a tracked process to the isolation context.
  """
  @spec add_tracked_process(IsolationContext.t(), IsolationContext.process_info()) ::
          IsolationContext.t()
  def add_tracked_process(%IsolationContext{} = ctx, process_info) when is_map(process_info) do
    %{ctx | processes: [process_info | ctx.processes]}
  end

  @doc """
  Adds a tracked ETS table to the isolation context.
  """
  @spec add_tracked_ets_table(IsolationContext.t(), term()) :: IsolationContext.t()
  def add_tracked_ets_table(%IsolationContext{} = ctx, table) do
    %{ctx | ets_tables: [table | ctx.ets_tables]}
  end

  @doc """
  Adds a cleanup callback to the isolation context.
  """
  @spec add_cleanup_callback(IsolationContext.t(), (-> any())) :: IsolationContext.t()
  def add_cleanup_callback(%IsolationContext{} = ctx, callback) when is_function(callback, 0) do
    %{ctx | cleanup_callbacks: [callback | ctx.cleanup_callbacks]}
  end

  @doc """
  Returns whether the isolation type allows async testing.
  """
  @spec isolation_allows_async?(atom()) :: boolean()
  def isolation_allows_async?(:basic), do: true
  def isolation_allows_async?(:registry), do: true
  def isolation_allows_async?(:full_isolation), do: true
  def isolation_allows_async?(:contamination_detection), do: false

  @doc """
  Returns the timeout for the isolation type.
  """
  @spec isolation_timeout(atom()) :: non_neg_integer()
  def isolation_timeout(:basic), do: 5_000
  def isolation_timeout(:registry), do: 10_000
  def isolation_timeout(:full_isolation), do: 15_000
  def isolation_timeout(:contamination_detection), do: 30_000

  @doc """
  Verifies test isolation has been maintained.
  """
  @spec verify_test_isolation(map()) :: boolean()
  def verify_test_isolation(context) do
    case Map.get(context, :isolation_context) do
      %IsolationContext{processes: processes} ->
        Enum.all?(processes, fn %{pid: pid} -> Process.alive?(pid) end)

      _ ->
        true
    end
  end

  @doc """
  Waits for a supervision tree to be ready.
  """
  @spec wait_for_supervision_tree_ready(pid(), non_neg_integer()) ::
          {:ok, pid()} | {:error, :timeout}
  def wait_for_supervision_tree_ready(supervisor_pid, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_supervisor_ready(supervisor_pid, start_time, timeout)
  end

  # Private functions

  defp setup_basic_isolation(context) do
    {isolation_context, _test_id} = build_isolation_context(context, :basic)
    register_cleanup(isolation_context)
    {:ok, attach_context(context, isolation_context)}
  end

  defp setup_registry_isolation(context) do
    {isolation_context, test_id} = build_isolation_context(context, :registry)
    registry_name = :"test_registry_#{test_id}"

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    isolation_context =
      isolation_context
      |> Map.put(:registry, registry_name)
      |> add_cleanup_callback(fn -> GenServer.stop(registry_name) end)

    register_cleanup(isolation_context)

    {:ok, attach_context(context, isolation_context)}
  end

  defp setup_full_isolation(context) do
    {isolation_context, test_id} = build_isolation_context(context, :full_isolation)
    registry_name = :"test_registry_#{test_id}"

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    isolation_context =
      isolation_context
      |> Map.put(:registry, registry_name)
      |> add_cleanup_callback(fn -> GenServer.stop(registry_name) end)

    register_cleanup(isolation_context)

    {:ok, attach_context(context, isolation_context)}
  end

  defp setup_contamination_detection(context) do
    {isolation_context, _test_id} = build_isolation_context(context, :contamination_detection)

    isolation_context =
      isolation_context
      |> Map.put(:initial_processes, Process.list())
      |> Map.put(:initial_ets_tables, :ets.all())

    register_cleanup(isolation_context, fn ctx ->
      check_contamination(ctx)
      cleanup_isolation(ctx)
    end)

    {:ok, attach_context(context, isolation_context)}
  end

  defp build_isolation_context(context, isolation_type) do
    test_id = generate_test_id(context)
    tags = build_context_tags(context, test_id, isolation_type)
    {%IsolationContext{test_id: test_id, tags: tags}, test_id}
  end

  defp attach_context(context, isolation_context) do
    put_isolation_context(isolation_context)
    Map.put(context, :isolation_context, isolation_context)
  end

  defp register_cleanup(isolation_context, fun \\ &cleanup_isolation/1) do
    Env.on_exit(fn ->
      ctx = fetch_isolation_context() || isolation_context
      fun.(ctx)
      put_isolation_context(nil)
    end)
  end

  defp build_context_tags(context, test_id, isolation_type) do
    [:module, :test, :file, :line]
    |> Enum.reduce(%{isolation: isolation_type, test_id: test_id}, fn key, acc ->
      case Map.get(context, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp generate_test_id(context) do
    test_name =
      case context do
        %{case: case_atom, test: test_atom} -> "#{case_atom}_#{test_atom}"
        %{test: test_atom} -> Atom.to_string(test_atom)
        _ -> "anonymous"
      end

    timestamp = System.unique_integer([:positive])
    String.to_atom("#{test_name}_#{timestamp}")
  end

  defp cleanup_isolation(nil), do: :ok

  defp cleanup_isolation(%IsolationContext{} = isolation_context) do
    isolation_context.processes
    |> Enum.each(&stop_process_safely/1)

    isolation_context.ets_tables
    |> Enum.each(&delete_ets_table_safely/1)

    Enum.each(isolation_context.cleanup_callbacks, fn callback ->
      try do
        callback.()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp stop_process_safely(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :normal)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 -> Process.exit(pid, :kill)
      end
    end
  end

  defp delete_ets_table_safely(table) do
    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end
  end

  defp check_contamination(nil), do: :ok

  defp check_contamination(%IsolationContext{} = isolation_context) do
    current_processes = Process.list()
    current_ets_tables = :ets.all()

    tracked_processes = Enum.map(isolation_context.processes, & &1.pid)

    new_processes = current_processes -- isolation_context.initial_processes
    leaked_processes = new_processes -- tracked_processes

    new_ets_tables = current_ets_tables -- isolation_context.initial_ets_tables
    leaked_ets_tables = new_ets_tables -- isolation_context.ets_tables

    if leaked_processes != [] or leaked_ets_tables != [] do
      require Logger

      Logger.warning(
        "Test contamination detected for #{inspect(isolation_context.tags)} - leaked processes: #{inspect(leaked_processes)}, leaked ETS tables: #{inspect(leaked_ets_tables)}"
      )
    end
  end

  defp wait_for_supervisor_ready(supervisor_pid, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    remaining = timeout - (current_time - start_time)

    if remaining <= 0 do
      {:error, :timeout}
    else
      children = Supervisor.which_children(supervisor_pid)

      if Enum.all?(children, &child_ready?/1) do
        {:ok, supervisor_pid}
      else
        # Wait using receive timeout instead of Process.sleep
        receive do
        after
          min(10, remaining) -> :ok
        end

        wait_for_supervisor_ready(supervisor_pid, start_time, timeout)
      end
    end
  end

  defp child_ready?({_id, :undefined, _type, _modules}), do: false
  defp child_ready?({_id, pid, _type, _modules}) when is_pid(pid), do: Process.alive?(pid)
  defp child_ready?(_), do: false
end
