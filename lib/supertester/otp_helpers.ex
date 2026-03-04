defmodule Supertester.OTPHelpers do
  alias Supertester.Internal.{Poller, ProcessLifecycle, ProcessRef, ProcessWatch, SharedRegistry}

  @moduledoc """
  OTP-compliant testing utilities for GenServer, Supervisor, and process management.

  This module provides helpers that replace timing-based synchronization (Process.sleep)
  with proper OTP synchronization patterns, enabling reliable async testing.

  ## Key Features

  - Unique process naming to prevent conflicts
  - OTP-compliant synchronization without Process.sleep
  - Automatic resource cleanup
  - Process lifecycle management
  - Supervision tree testing utilities

  ## Usage

      import Supertester.OTPHelpers

      test "my genserver test" do
        {:ok, server} = setup_isolated_genserver(MyGenServer, "test_context")
        assert_genserver_responsive(server)
      end
  """

  @doc """
  Sets up an isolated GenServer with unique naming and automatic cleanup.

  ## Parameters

  - `module` - The GenServer module to start
  - `test_name` - Test context for unique naming (optional)
  - `opts` - Options passed to GenServer.start_link (optional)

  ## Returns

  `{:ok, server_pid}` or `{:error, reason}`

  ## Example

      {:ok, server} = setup_isolated_genserver(MyGenServer, "my_test", [initial_state: %{}])
  """
  @spec setup_isolated_genserver(module(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def setup_isolated_genserver(module, test_name \\ "", opts \\ []) do
    setup_isolated_process(:genserver, module, test_name, opts)
  end

  @doc """
  Sets up an isolated Supervisor with unique naming and automatic cleanup.

  ## Parameters

  - `module` - The Supervisor module to start
  - `test_name` - Test context for unique naming (optional)
  - `opts` - Options passed to Supervisor.start_link (optional)

  ## Returns

  `{:ok, supervisor_pid}` or `{:error, reason}`

  ## Example

      {:ok, supervisor} = setup_isolated_supervisor(MySupervisor, "my_test")
  """
  @spec setup_isolated_supervisor(module(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def setup_isolated_supervisor(module, test_name \\ "", opts \\ []) do
    setup_isolated_process(:supervisor, module, test_name, opts)
  end

  @doc """
  Waits for a GenServer to be synchronized and responsive.

  Uses GenServer.call with a sync message instead of Process.sleep.

  ## Parameters

  - `server` - The GenServer pid or name
  - `timeout` - Timeout in milliseconds (default: 1000)

  ## Returns

  `:ok` if server is responsive, `{:error, reason}` otherwise

  ## Example

      wait_for_genserver_sync(server, 5000)
  """
  @spec wait_for_genserver_sync(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def wait_for_genserver_sync(server, timeout \\ 1000) do
    # Use a synchronous call to ensure the server is responsive
    GenServer.call(server, :__supertester_sync__, timeout)
    :ok
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @doc """
  Waits for a process to restart after termination.

  ## Parameters

  - `process_name` - The registered name of the process
  - `original_pid` - The PID before restart
  - `timeout` - Timeout in milliseconds (default: 1000)

  ## Returns

  `{:ok, new_pid}` if process restarted, `{:error, reason}` otherwise

  ## Example

      original_pid = GenServer.whereis(MyServer)
      GenServer.stop(MyServer)
      {:ok, new_pid} = wait_for_process_restart(MyServer, original_pid)
  """
  @spec wait_for_process_restart(atom(), pid(), timeout()) :: {:ok, pid()} | {:error, term()}
  def wait_for_process_restart(process_name, original_pid, timeout \\ 1000) do
    Poller.until(fn -> restart_probe(process_name, original_pid) end, timeout, 5)
  end

  @doc """
  Waits for a supervisor to finish starting all its children.

  ## Parameters

  - `supervisor` - The supervisor pid or name
  - `timeout` - Timeout in milliseconds (default: 1000)

  ## Returns

  `:ok` if supervisor is ready, `{:error, reason}` otherwise

  ## Example

      {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)
      wait_for_supervisor_restart(supervisor)
  """
  @spec wait_for_supervisor_restart(Supervisor.supervisor(), timeout()) ::
          {:ok, pid()} | {:error, term()}
  def wait_for_supervisor_restart(supervisor, timeout \\ 1000) do
    Supertester.UnifiedTestFoundation.wait_for_supervision_tree_ready(supervisor, timeout)
  end

  @doc """
  Monitors a process lifecycle and returns monitoring information.

  ## Parameters

  - `pid` - The process to monitor

  ## Returns

  `{monitor_ref, pid}`

  ## Example

      {ref, pid} = monitor_process_lifecycle(server_pid)
  """
  @spec monitor_process_lifecycle(pid()) :: {reference(), pid()}
  def monitor_process_lifecycle(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    {ref, pid}
  end

  @doc """
  Waits for a process to terminate.

  ## Parameters

  - `pid` - The process to wait for
  - `timeout` - Timeout in milliseconds (default: 1000)

  ## Returns

  `{:ok, reason}` if process died, `{:error, :timeout}` if timeout

  ## Example

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      {:ok, :killed} = wait_for_process_death(pid)
  """
  @spec wait_for_process_death(pid(), timeout()) :: {:ok, term()} | {:error, :timeout}
  def wait_for_process_death(pid, timeout \\ 1000) when is_pid(pid) do
    ref = Process.monitor(pid)

    case ProcessWatch.await_down(ref, pid, timeout) do
      {:down, reason} -> {:ok, reason}
      :timeout -> {:error, :timeout}
    end
  end

  @doc """
  Cleans up a list of processes safely.

  ## Parameters

  - `pids` - List of PIDs to clean up

  ## Example

      cleanup_processes([pid1, pid2, pid3])
  """
  @spec cleanup_processes([pid()]) :: :ok
  def cleanup_processes(pids) when is_list(pids) do
    Enum.each(pids, &ProcessLifecycle.stop_process_safely/1)
  end

  @doc """
  Registers a cleanup function to run on test exit.

  ## Parameters

  - `cleanup_fun` - Function to call on test exit

  ## Example

      cleanup_on_exit(fn -> GenServer.stop(my_server) end)
  """
  @spec cleanup_on_exit((-> any())) :: :ok
  def cleanup_on_exit(cleanup_fun) when is_function(cleanup_fun, 0) do
    Supertester.Env.on_exit(cleanup_fun)
  end

  # Private functions

  defp setup_isolated_process(kind, module, test_name, opts) do
    unique_name = generate_unique_process_name(module, test_name)
    {init_args, start_opts} = split_start_opts(kind, opts, unique_name)

    case safe_start(kind, module, init_args, start_opts) do
      {:ok, pid} ->
        track_process(%{pid: pid, name: Keyword.get(start_opts, :name), module: module})
        cleanup_on_exit(fn -> stop_isolated_process(kind, pid) end)
        {:ok, pid}

      {:error, reason} ->
        {:error,
         {:start_failed, build_failure_metadata(kind, module, start_opts, init_args, reason)}}
    end
  end

  defp split_start_opts(:genserver, opts, unique_name) do
    opts
    |> maybe_put_name(unique_name)
    |> Keyword.pop(:init_args, [])
  end

  defp split_start_opts(:supervisor, opts, unique_name) do
    {init_args, base_opts} = Keyword.pop(opts, :init_args, [])
    {init_args, maybe_put_name(base_opts, unique_name)}
  end

  defp maybe_put_name(opts, unique_name) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.put(opts, :name, unique_name)
      _existing_name -> opts
    end
  end

  defp stop_isolated_process(:genserver, pid), do: ProcessLifecycle.stop_genserver_safely(pid)
  defp stop_isolated_process(:supervisor, pid), do: ProcessLifecycle.stop_supervisor_safely(pid)

  defp safe_start(kind, module, init_args, opts) do
    parent = self()
    result_ref = make_ref()

    starter =
      spawn(fn ->
        result =
          try do
            case kind do
              :genserver -> GenServer.start_link(module, init_args, opts)
              :supervisor -> Supervisor.start_link(module, init_args, opts)
            end
          catch
            :exit, reason -> {:error, reason}
          end

        send(parent, {result_ref, result})
      end)

    monitor_ref = Process.monitor(starter)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^starter, reason} ->
        {:error, reason}
    after
      5_000 ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :start_timeout}
    end
  end

  defp track_process(process_info) do
    if isolation_context = Supertester.UnifiedTestFoundation.fetch_isolation_context() do
      isolation_context
      |> Supertester.UnifiedTestFoundation.add_tracked_process(process_info)
      |> Supertester.UnifiedTestFoundation.put_isolation_context()
    end
  end

  defp build_failure_metadata(kind, module, opts, init_args, reason) do
    %{
      kind: kind,
      module: module,
      name: Keyword.get(opts, :name),
      init_args: init_args,
      reason: reason,
      tags: failure_tags()
    }
  end

  defp failure_tags do
    case Supertester.UnifiedTestFoundation.fetch_isolation_context() do
      %Supertester.IsolationContext{tags: tags} -> tags
      _ -> %{}
    end
  end

  defp generate_unique_process_name(module, test_name) do
    SharedRegistry.ensure_started()

    module_segment =
      module
      |> Module.split()
      |> List.last()
      |> normalize_segment()

    logical_segment = normalize_segment(test_name)
    serial = System.unique_integer([:positive, :monotonic])
    test_segment = isolation_test_segment()

    key =
      [module_segment, logical_segment, test_segment]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("_")
      |> case do
        "" -> "supertester_process"
        value -> value
      end

    {:via, Registry, {SharedRegistry.name(), {:supertester, module, key, serial}}}
  end

  defp isolation_test_segment do
    case Supertester.UnifiedTestFoundation.fetch_isolation_context() do
      %Supertester.IsolationContext{test_id: test_id} -> normalize_segment(test_id)
      _ -> nil
    end
  end

  defp normalize_segment(nil), do: nil
  defp normalize_segment(""), do: nil
  defp normalize_segment(value) when is_atom(value), do: normalize_segment(Atom.to_string(value))

  defp normalize_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp restart_probe(process_name, original_pid) do
    case ProcessRef.resolve(process_name) do
      nil ->
        :retry

      ^original_pid ->
        :retry

      new_pid ->
        case wait_for_genserver_sync(new_pid, 100) do
          :ok -> {:ok, new_pid}
          {:error, _} -> :retry
        end
    end
  end
end
