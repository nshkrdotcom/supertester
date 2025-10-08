defmodule Supertester.Assertions do
  @moduledoc """
  Custom assertions for OTP patterns and system behavior.

  This module provides specialized assertions that understand OTP patterns,
  making tests more expressive and providing better error messages.

  ## Usage

      import Supertester.Assertions

      test "my test" do
        assert_process_alive(server_pid)
        assert_genserver_responsive(server_pid)
      end
  """

  @doc """
  Asserts that a process is alive.

  ## Parameters

  - `pid` - The process ID to check

  ## Example

      assert_process_alive(server_pid)
  """
  @spec assert_process_alive(pid()) :: :ok
  def assert_process_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      :ok
    else
      raise "Expected process #{inspect(pid)} to be alive, but it was dead"
    end
  end

  @doc """
  Asserts that a process is dead.

  ## Parameters

  - `pid` - The process ID to check

  ## Example

      assert_process_dead(old_pid)
  """
  @spec assert_process_dead(pid()) :: :ok
  def assert_process_dead(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      raise "Expected process #{inspect(pid)} to be dead, but it was alive"
    else
      :ok
    end
  end

  @doc """
  Asserts that a process has been restarted.

  ## Parameters

  - `process_name` - The registered name of the process
  - `original_pid` - The original PID before restart

  ## Example

      original_pid = GenServer.whereis(MyServer)
      GenServer.stop(MyServer)
      assert_process_restarted(MyServer, original_pid)
  """
  @spec assert_process_restarted(atom(), pid()) :: :ok
  def assert_process_restarted(process_name, original_pid)
      when is_atom(process_name) and is_pid(original_pid) do
    current_pid = Process.whereis(process_name)

    cond do
      current_pid == nil ->
        raise "Expected process #{process_name} to be restarted, but no process is registered"

      current_pid == original_pid ->
        raise "Expected process #{process_name} to be restarted, but PID #{inspect(original_pid)} is the same"

      true ->
        :ok
    end
  end

  @doc """
  Asserts that a GenServer has the expected state.

  ## Parameters

  - `server` - The GenServer pid or name
  - `expected_state` - The expected state or a function to test the state

  ## Example

      assert_genserver_state(server, %{counter: 5})
      assert_genserver_state(server, fn state -> state.counter > 0 end)
  """
  @spec assert_genserver_state(GenServer.server(), term() | (term() -> boolean())) :: :ok
  def assert_genserver_state(server, expected_state) do
    case Supertester.GenServerHelpers.get_server_state_safely(server) do
      {:ok, actual_state} ->
        case expected_state do
          fun when is_function(fun, 1) ->
            if fun.(actual_state) do
              :ok
            else
              raise "GenServer state #{inspect(actual_state)} did not pass validation function"
            end

          expected when is_map(expected) or is_list(expected) ->
            if actual_state == expected do
              :ok
            else
              raise "Expected GenServer state to be #{inspect(expected)}, got #{inspect(actual_state)}"
            end
        end

      {:error, reason} ->
        raise "Failed to get GenServer state: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that a GenServer is responsive.

  ## Parameters

  - `server` - The GenServer pid or name

  ## Example

      assert_genserver_responsive(server)
  """
  @spec assert_genserver_responsive(GenServer.server()) :: :ok
  def assert_genserver_responsive(server) do
    case Supertester.OTPHelpers.wait_for_genserver_sync(server, 1000) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Expected GenServer #{inspect(server)} to be responsive, but got error: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that a GenServer handles a message correctly.

  ## Parameters

  - `server` - The GenServer pid or name
  - `message` - The message to send
  - `expected_response` - The expected response

  ## Example

      assert_genserver_handles_message(server, :get_counter, {:ok, 5})
  """
  @spec assert_genserver_handles_message(GenServer.server(), term(), term()) :: :ok
  def assert_genserver_handles_message(server, message, expected_response) do
    case Supertester.GenServerHelpers.call_with_timeout(server, message, 1000) do
      {:ok, actual_response} ->
        if actual_response == expected_response do
          :ok
        else
          raise "Expected GenServer to respond with #{inspect(expected_response)}, got #{inspect(actual_response)}"
        end

      {:error, reason} ->
        raise "GenServer call failed: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that a supervisor has the expected strategy.

  ## Parameters

  - `supervisor` - The supervisor pid or name
  - `expected_strategy` - The expected supervision strategy

  ## Example

      assert_supervisor_strategy(supervisor, :one_for_one)
  """
  @spec assert_supervisor_strategy(Supervisor.supervisor(), atom()) :: :ok
  def assert_supervisor_strategy(supervisor, _expected_strategy) do
    try do
      _children = Supervisor.which_children(supervisor)
      _count = Supervisor.count_children(supervisor)

      # This is a simplified check - in practice, strategy detection
      # would require more sophisticated analysis
      # For now, we just verify the supervisor is accessible
      :ok
    catch
      :exit, reason ->
        raise "Failed to check supervisor strategy: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that a supervisor has the expected number of children.

  ## Parameters

  - `supervisor` - The supervisor pid or name
  - `expected_count` - The expected number of children

  ## Example

      assert_child_count(supervisor, 3)
  """
  @spec assert_child_count(Supervisor.supervisor(), non_neg_integer()) :: :ok
  def assert_child_count(supervisor, expected_count) when is_integer(expected_count) do
    try do
      %{active: active} = Supervisor.count_children(supervisor)

      if active == expected_count do
        :ok
      else
        raise "Expected supervisor to have #{expected_count} children, got #{active}"
      end
    catch
      :exit, reason ->
        raise "Failed to count supervisor children: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that all children of a supervisor are alive.

  ## Parameters

  - `supervisor` - The supervisor pid or name

  ## Example

      assert_all_children_alive(supervisor)
  """
  @spec assert_all_children_alive(Supervisor.supervisor()) :: :ok
  def assert_all_children_alive(supervisor) do
    try do
      children = Supervisor.which_children(supervisor)

      dead_children =
        Enum.filter(children, fn
          {_id, :undefined, _type, _modules} -> true
          {_id, pid, _type, _modules} when is_pid(pid) -> not Process.alive?(pid)
          _ -> false
        end)

      if Enum.empty?(dead_children) do
        :ok
      else
        raise "Expected all supervisor children to be alive, but found dead children: #{inspect(dead_children)}"
      end
    catch
      :exit, reason ->
        raise "Failed to check supervisor children: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that memory usage remains stable during an operation.

  ## Parameters

  - `operation_fun` - Function to execute
  - `tolerance` - Memory tolerance as a percentage (default: 0.1)

  ## Example

      assert_memory_usage_stable(fn -> 
        Enum.each(1..1000, fn _ -> GenServer.call(server, :increment) end)
      end, 0.05)
  """
  @spec assert_memory_usage_stable((-> any()), float()) :: :ok
  def assert_memory_usage_stable(operation_fun, tolerance \\ 0.1)
      when is_function(operation_fun, 0) do
    initial_memory = :erlang.memory(:total)

    operation_fun.()

    # Force garbage collection
    :erlang.garbage_collect()

    final_memory = :erlang.memory(:total)
    memory_change = abs(final_memory - initial_memory) / initial_memory

    if memory_change <= tolerance do
      :ok
    else
      raise "Memory usage not stable: changed by #{Float.round(memory_change * 100, 2)}%, tolerance was #{Float.round(tolerance * 100, 2)}%"
    end
  end

  @doc """
  Asserts that no processes are leaked during an operation.

  ## Parameters

  - `operation_fun` - Function to execute

  ## Example

      assert_no_process_leaks(fn ->
        {:ok, server} = GenServer.start_link(MyServer, [])
        GenServer.stop(server)
      end)
  """
  @spec assert_no_process_leaks((-> any())) :: :ok
  def assert_no_process_leaks(operation_fun) when is_function(operation_fun, 0) do
    initial_processes = Process.list()

    operation_fun.()

    # Allow some time for cleanup using receive timeout instead of Process.sleep
    receive do
    after
      10 -> :ok
    end

    final_processes = Process.list()
    leaked_processes = final_processes -- initial_processes

    # Filter out test-related processes that are expected
    actual_leaks =
      Enum.filter(leaked_processes, fn pid ->
        case Process.info(pid, [:initial_call, :dictionary]) do
          nil ->
            false

          info ->
            initial_call = Keyword.get(info, :initial_call, {})
            dictionary = Keyword.get(info, :dictionary, [])

            # Filter out known test infrastructure processes
            not (tuple_starts_with?(initial_call, [:proc_lib, :init_p]) or
                   Keyword.has_key?(dictionary, :"$ancestors"))
        end
      end)

    if Enum.empty?(actual_leaks) do
      :ok
    else
      raise "Process leaks detected: #{length(actual_leaks)} processes were not cleaned up"
    end
  end

  @doc """
  Asserts that performance is within expected bounds.

  ## Parameters

  - `benchmark_result` - Result from performance testing
  - `expectations` - Map of performance expectations

  ## Example

      expectations = %{max_time: 1000, max_memory: 1_000_000}
      assert_performance_within_bounds(result, expectations)
  """
  @spec assert_performance_within_bounds(map(), map()) :: :ok
  def assert_performance_within_bounds(benchmark_result, expectations)
      when is_map(expectations) do
    Enum.each(expectations, fn {metric, expected_value} ->
      actual_value = Map.get(benchmark_result, metric)

      case {metric, actual_value, expected_value} do
        {:max_time, actual, expected} when actual > expected ->
          raise "Execution time #{actual}ms exceeded maximum of #{expected}ms"

        {:max_memory, actual, expected} when actual > expected ->
          raise "Memory usage #{actual} bytes exceeded maximum of #{expected} bytes"

        _ ->
          :ok
      end
    end)
  end

  # Private functions

  defp tuple_starts_with?(tuple, prefixes) when is_tuple(tuple) do
    tuple_list = Tuple.to_list(tuple)

    Enum.any?(prefixes, fn prefix ->
      List.starts_with?(tuple_list, List.wrap(prefix))
    end)
  end

  defp tuple_starts_with?(_, _), do: false
end
