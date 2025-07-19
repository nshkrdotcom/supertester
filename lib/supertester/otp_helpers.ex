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
  def setup_isolated_genserver(module, test_name \\ "", opts \\ []) do
    unique_name = generate_unique_process_name(module, test_name)

    server_opts =
      case Keyword.get(opts, :name) do
        nil -> Keyword.put(opts, :name, unique_name)
        _existing_name -> opts
      end

    # Separate init_args from GenServer options
    {init_args, genserver_opts} = Keyword.pop(server_opts, :init_args, [])

    case GenServer.start_link(module, init_args, genserver_opts) do
      {:ok, pid} ->
        # Register for cleanup
        isolation_context = Process.get(:isolation_context, %{})
        process_info = %{pid: pid, name: unique_name, module: module}
        updated_processes = [process_info | Map.get(isolation_context, :processes, [])]
        updated_context = Map.put(isolation_context, :processes, updated_processes)
        Process.put(:isolation_context, updated_context)

        # Setup automatic cleanup
        cleanup_on_exit(fn -> stop_genserver_safely(pid) end)

        {:ok, pid}

      error ->
        error
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
  def setup_isolated_supervisor(module, test_name \\ "", opts \\ []) do
    unique_name = generate_unique_process_name(module, test_name)

    supervisor_opts =
      case Keyword.get(opts, :name) do
        nil -> Keyword.put(opts, :name, unique_name)
        _existing_name -> opts
      end

    case Supervisor.start_link(module, opts, supervisor_opts) do
      {:ok, pid} ->
        # Register for cleanup
        isolation_context = Process.get(:isolation_context, %{})
        process_info = %{pid: pid, name: unique_name, module: module}
        updated_processes = [process_info | Map.get(isolation_context, :processes, [])]
        updated_context = Map.put(isolation_context, :processes, updated_processes)
        Process.put(:isolation_context, updated_context)

        # Setup automatic cleanup
        cleanup_on_exit(fn -> stop_supervisor_safely(pid) end)

        {:ok, pid}

      error ->
        error
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
  def wait_for_genserver_sync(server, timeout \\ 1000) do
    try do
      # Use a synchronous call to ensure the server is responsive
      GenServer.call(server, :__supertester_sync__, timeout)
      :ok
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
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
  def cleanup_on_exit(cleanup_fun) when is_function(cleanup_fun, 0) do
    # This function is meant to be used within test contexts where ExUnit.Callbacks is available
    # The actual implementation will be injected by the test case
    apply(ExUnit.Callbacks, :on_exit, [cleanup_fun])
  end

  # Private functions

  defp generate_unique_process_name(module, test_name) do
    module_name = module |> Module.split() |> List.last()
    timestamp = System.unique_integer([:positive])
    test_suffix = if test_name != "", do: "_#{test_name}", else: ""

    :"#{module_name}#{test_suffix}_#{timestamp}"
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
      try do
        Supervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ ->
          Process.exit(pid, :kill)
      end
    end
  end

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

    if current_time - start_time > timeout do
      {:error, :timeout}
    else
      case Process.whereis(process_name) do
        nil ->
          Process.sleep(5)
          wait_for_restart_loop(process_name, original_pid, start_time, timeout)

        ^original_pid ->
          Process.sleep(5)
          wait_for_restart_loop(process_name, original_pid, start_time, timeout)

        new_pid when is_pid(new_pid) ->
          # Verify the new process is responsive
          case wait_for_genserver_sync(new_pid, 100) do
            :ok ->
              {:ok, new_pid}

            {:error, _} ->
              Process.sleep(5)
              wait_for_restart_loop(process_name, original_pid, start_time, timeout)
          end
      end
    end
  end
end
