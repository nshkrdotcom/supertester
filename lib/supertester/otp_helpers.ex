defmodule Supertester.OTPHelpers do
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
    unique_name = generate_unique_process_name(module, test_name)

    server_opts =
      case Keyword.get(opts, :name) do
        nil -> Keyword.put(opts, :name, unique_name)
        _existing_name -> opts
      end

    # Separate init_args from GenServer options
    {init_args, genserver_opts} = Keyword.pop(server_opts, :init_args, [])

    case safe_start(:genserver, module, init_args, genserver_opts) do
      {:ok, pid} ->
        track_process(%{pid: pid, name: Keyword.get(genserver_opts, :name), module: module})
        cleanup_on_exit(fn -> stop_genserver_safely(pid) end)
        {:ok, pid}

      {:error, reason} ->
        {:error,
         {:start_failed,
          build_failure_metadata(:genserver, module, genserver_opts, init_args, reason)}}
    end
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
    unique_name = generate_unique_process_name(module, test_name)

    supervisor_opts =
      case Keyword.get(opts, :name) do
        nil -> Keyword.put(opts, :name, unique_name)
        _existing_name -> opts
      end

    case safe_start(:supervisor, module, opts, supervisor_opts) do
      {:ok, pid} ->
        track_process(%{pid: pid, name: Keyword.get(supervisor_opts, :name), module: module})
        cleanup_on_exit(fn -> stop_supervisor_safely(pid) end)
        {:ok, pid}

      {:error, reason} ->
        {:error,
         {:start_failed,
          build_failure_metadata(:supervisor, module, supervisor_opts, opts, reason)}}
    end
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
    start_time = System.monotonic_time(:millisecond)
    wait_for_restart_loop(process_name, original_pid, start_time, timeout)
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

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:ok, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
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
    Enum.each(pids, &stop_process_safely/1)
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

  defp safe_start(kind, module, init_args, opts) do
    original_flag = Process.flag(:trap_exit, true)

    result =
      try do
        case kind do
          :genserver -> GenServer.start_link(module, init_args, opts)
          :supervisor -> Supervisor.start_link(module, init_args, opts)
        end
      catch
        :exit, reason -> {:error, reason}
      after
        if original_flag == false do
          drain_exit_messages()
        end

        Process.flag(:trap_exit, original_flag)
      end

    result
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

  defp drain_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> drain_exit_messages()
    after
      0 -> :ok
    end
  end

  defp generate_unique_process_name(module, test_name) do
    module_segment =
      module
      |> Module.split()
      |> List.last()
      |> normalize_segment()

    logical_segment = normalize_segment(test_name)

    case Supertester.UnifiedTestFoundation.fetch_isolation_context() do
      %Supertester.IsolationContext{test_id: test_id} ->
        [module_segment, logical_segment, normalize_segment(test_id)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("_")
        |> String.to_atom()

      _ ->
        timestamp = System.unique_integer([:positive])

        [module_segment, logical_segment, Integer.to_string(timestamp)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("_")
        |> String.to_atom()
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

  defp stop_genserver_safely(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ ->
          Process.exit(pid, :kill)
      end
    end
  end

  defp stop_supervisor_safely(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Enum.each(Supervisor.which_children(pid), fn
        {_id, child_pid, _type, _modules} when is_pid(child_pid) ->
          stop_process_safely(%{pid: child_pid})

        _ ->
          :ok
      end)

      try do
        Supervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ ->
          Process.exit(pid, :kill)
      end
    end
  end

  defp stop_process_safely(%{pid: pid}) when is_pid(pid), do: stop_process_safely(pid)

  defp stop_process_safely(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :normal)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
      end
    end
  end

  defp wait_for_restart_loop(process_name, original_pid, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    remaining = timeout - (current_time - start_time)

    if remaining <= 0 do
      {:error, :timeout}
    else
      current_pid = Process.whereis(process_name)

      check_restart_status(
        process_name,
        original_pid,
        current_pid,
        remaining,
        start_time,
        timeout
      )
    end
  end

  defp check_restart_status(process_name, original_pid, nil, remaining, start_time, timeout) do
    wait_and_retry_restart(process_name, original_pid, remaining, start_time, timeout)
  end

  defp check_restart_status(
         process_name,
         original_pid,
         current_pid,
         remaining,
         start_time,
         timeout
       )
       when current_pid == original_pid do
    wait_and_retry_restart(process_name, original_pid, remaining, start_time, timeout)
  end

  defp check_restart_status(process_name, original_pid, new_pid, remaining, start_time, timeout) do
    case wait_for_genserver_sync(new_pid, 100) do
      :ok ->
        {:ok, new_pid}

      {:error, _} ->
        wait_and_retry_restart(process_name, original_pid, remaining, start_time, timeout)
    end
  end

  defp wait_and_retry_restart(process_name, original_pid, remaining, start_time, timeout) do
    receive do
    after
      min(5, remaining) -> :ok
    end

    wait_for_restart_loop(process_name, original_pid, start_time, timeout)
  end
end
