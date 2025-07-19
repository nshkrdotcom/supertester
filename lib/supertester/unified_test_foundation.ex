defmodule Supertester.UnifiedTestFoundation do
  @moduledoc """
  Unified test foundation providing multiple isolation modes for OTP testing.

  This module provides macros and utilities to establish different levels of test isolation,
  enabling async testing while preventing process conflicts and ensuring proper cleanup.

  ## Isolation Modes

  - `:basic` - Basic isolation with unique naming
  - `:registry` - Registry-based process isolation
  - `:full_isolation` - Complete process and ETS isolation
  - `:contamination_detection` - Isolation with contamination detection

  ## Usage

      defmodule MyApp.MyModuleTest do
        use ExUnit.Case
        use Supertester.UnifiedTestFoundation, isolation: :full_isolation

        test "my test", context do
          # Test runs with full isolation
        end
      end
  """

  @doc """
  Provides test isolation setup based on the specified isolation type.
  """
  defmacro __using__(opts) do
    isolation_type = Keyword.get(opts, :isolation, :basic)

    quote do
      import Supertester.UnifiedTestFoundation

      setup context do
        Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation_type), context)
      end

      # Determine if tests can run async based on isolation type
      if Supertester.UnifiedTestFoundation.isolation_allows_async?(unquote(isolation_type)) do
        use ExUnit.Case, async: true
      else
        use ExUnit.Case, async: false
      end
    end
  end

  @doc """
  Sets up test isolation based on the specified isolation type.
  """
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
  Returns whether the isolation type allows async testing.
  """
  def isolation_allows_async?(:basic), do: true
  def isolation_allows_async?(:registry), do: true
  def isolation_allows_async?(:full_isolation), do: true
  def isolation_allows_async?(:contamination_detection), do: false

  @doc """
  Returns the timeout for the isolation type.
  """
  def isolation_timeout(:basic), do: 5_000
  def isolation_timeout(:registry), do: 10_000
  def isolation_timeout(:full_isolation), do: 15_000
  def isolation_timeout(:contamination_detection), do: 30_000

  @doc """
  Verifies test isolation has been maintained.
  """
  def verify_test_isolation(context) do
    isolation_context = Map.get(context, :isolation_context, %{})

    # Verify all processes are still running and isolated
    processes = Map.get(isolation_context, :processes, [])
    Enum.all?(processes, fn %{pid: pid} -> Process.alive?(pid) end)
  end

  @doc """
  Waits for a supervision tree to be ready.
  """
  def wait_for_supervision_tree_ready(supervisor_pid, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_supervisor_ready(supervisor_pid, start_time, timeout)
  end

  # Private functions

  defp setup_basic_isolation(context) do
    test_id = generate_test_id(context)

    isolation_context = %{
      test_id: test_id,
      processes: [],
      cleanup_callbacks: []
    }

    apply(ExUnit.Callbacks, :on_exit, [fn -> cleanup_isolation(isolation_context) end])

    {:ok, Map.put(context, :isolation_context, isolation_context)}
  end

  defp setup_registry_isolation(context) do
    test_id = generate_test_id(context)
    registry_name = :"test_registry_#{test_id}"

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    isolation_context = %{
      test_id: test_id,
      registry: registry_name,
      processes: [],
      cleanup_callbacks: [fn -> GenServer.stop(registry_name) end]
    }

    apply(ExUnit.Callbacks, :on_exit, [fn -> cleanup_isolation(isolation_context) end])

    {:ok, Map.put(context, :isolation_context, isolation_context)}
  end

  defp setup_full_isolation(context) do
    test_id = generate_test_id(context)
    registry_name = :"test_registry_#{test_id}"

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    isolation_context = %{
      test_id: test_id,
      registry: registry_name,
      processes: [],
      ets_tables: [],
      cleanup_callbacks: [fn -> GenServer.stop(registry_name) end]
    }

    apply(ExUnit.Callbacks, :on_exit, [fn -> cleanup_isolation(isolation_context) end])

    {:ok, Map.put(context, :isolation_context, isolation_context)}
  end

  defp setup_contamination_detection(context) do
    test_id = generate_test_id(context)

    # Capture initial system state
    initial_processes = Process.list()
    initial_ets_tables = :ets.all()

    isolation_context = %{
      test_id: test_id,
      initial_processes: initial_processes,
      initial_ets_tables: initial_ets_tables,
      processes: [],
      ets_tables: [],
      cleanup_callbacks: []
    }

    apply(ExUnit.Callbacks, :on_exit, [
      fn ->
        check_contamination(isolation_context)
        cleanup_isolation(isolation_context)
      end
    ])

    {:ok, Map.put(context, :isolation_context, isolation_context)}
  end

  defp generate_test_id(context) do
    test_name =
      case context do
        %{test: test_atom} -> Atom.to_string(test_atom)
        %{case: case_atom, test: test_atom} -> "#{case_atom}_#{test_atom}"
        _ -> "anonymous"
      end

    timestamp = System.unique_integer([:positive])
    String.to_atom("#{test_name}_#{timestamp}")
  end

  defp cleanup_isolation(isolation_context) do
    # Stop all tracked processes
    isolation_context
    |> Map.get(:processes, [])
    |> Enum.each(&stop_process_safely/1)

    # Clean up ETS tables
    isolation_context
    |> Map.get(:ets_tables, [])
    |> Enum.each(&delete_ets_table_safely/1)

    # Run cleanup callbacks
    isolation_context
    |> Map.get(:cleanup_callbacks, [])
    |> Enum.each(fn callback ->
      try do
        callback.()
      rescue
        _ -> :ok
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

  defp check_contamination(isolation_context) do
    current_processes = Process.list()
    current_ets_tables = :ets.all()

    initial_processes = Map.get(isolation_context, :initial_processes, [])
    initial_ets_tables = Map.get(isolation_context, :initial_ets_tables, [])

    # Check for process leaks
    new_processes = current_processes -- initial_processes
    leaked_processes = new_processes -- Map.get(isolation_context, :processes, [])

    # Check for ETS table leaks  
    new_ets_tables = current_ets_tables -- initial_ets_tables
    leaked_ets_tables = new_ets_tables -- Map.get(isolation_context, :ets_tables, [])

    if length(leaked_processes) > 0 or length(leaked_ets_tables) > 0 do
      require Logger

      Logger.warning(
        "Test contamination detected - leaked processes: #{inspect(leaked_processes)}, leaked ETS tables: #{inspect(leaked_ets_tables)}"
      )
    end
  end

  defp wait_for_supervisor_ready(supervisor_pid, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time > timeout do
      {:error, :timeout}
    else
      children = Supervisor.which_children(supervisor_pid)

      if Enum.all?(children, &child_ready?/1) do
        {:ok, supervisor_pid}
      else
        Process.sleep(10)
        wait_for_supervisor_ready(supervisor_pid, start_time, timeout)
      end
    end
  end

  defp child_ready?({_id, :undefined, _type, _modules}), do: false
  defp child_ready?({_id, pid, _type, _modules}) when is_pid(pid), do: Process.alive?(pid)
  defp child_ready?(_), do: false
end
