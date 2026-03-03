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
        validate_genserver_state(actual_state, expected_state)

      {:error, reason} ->
        raise "Failed to get GenServer state: #{inspect(reason)}"
    end
  end

  defp validate_genserver_state(actual_state, fun) when is_function(fun, 1) do
    if fun.(actual_state) do
      :ok
    else
      raise "GenServer state #{inspect(actual_state)} did not pass validation function"
    end
  end

  defp validate_genserver_state(actual_state, expected)
       when is_map(expected) or is_list(expected) do
    if actual_state == expected do
      :ok
    else
      raise "Expected GenServer state to be #{inspect(expected)}, got #{inspect(actual_state)}"
    end
  end

  defp validate_genserver_state(actual_state, expected) do
    if actual_state == expected do
      :ok
    else
      raise "Expected GenServer state to be #{inspect(expected)}, got #{inspect(actual_state)}"
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
  Asserts that a supervisor is accessible and running.

  This function validates the runtime supervisor strategy by inspecting the
  supervisor state through OTP system introspection APIs.

  ## Parameters

  - `supervisor` - The supervisor pid or name
  - `expected_strategy` - The expected strategy (:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one)

  ## Example

      assert_supervisor_strategy(supervisor, :one_for_one)
  """
  @spec assert_supervisor_strategy(Supervisor.supervisor(), atom()) :: :ok
  def assert_supervisor_strategy(supervisor, expected_strategy) do
    case extract_supervisor_strategy(supervisor) do
      nil ->
        raise "Unable to determine supervisor strategy for #{inspect(supervisor)}"

      ^expected_strategy ->
        :ok

      actual ->
        raise "Expected supervisor strategy #{inspect(expected_strategy)}, got #{inspect(actual)}"
    end
  catch
    :exit, reason ->
      raise "Failed to inspect supervisor strategy: #{inspect(reason)}"
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

  @doc """
  Asserts that all children of a supervisor are alive.

  ## Parameters

  - `supervisor` - The supervisor pid or name

  ## Example

      assert_all_children_alive(supervisor)
  """
  @spec assert_all_children_alive(Supervisor.supervisor()) :: :ok
  def assert_all_children_alive(supervisor) do
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
    initial_links = linked_processes(self())
    spawned_processes = capture_spawned_processes(operation_fun)

    # Allow some time for cleanup using receive timeout instead of Process.sleep
    receive do
    after
      10 -> :ok
    end

    final_links = linked_processes(self())
    linked_candidates = final_links -- initial_links
    leak_candidates = Enum.uniq(spawned_processes ++ linked_candidates)

    # Ignore transient processes that disappear quickly, but keep persistent leaks.
    # Candidate leaks are limited to processes spawned by or linked to the operation caller.
    actual_leaks =
      Enum.filter(leak_candidates, fn pid ->
        Process.alive?(pid) and persistent_process?(pid, 20) and reportable_process?(pid)
      end)

    if Enum.empty?(actual_leaks) do
      :ok
    else
      raise "Process leaks detected: #{length(actual_leaks)} processes were not cleaned up (#{inspect(actual_leaks)})"
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

  @strategies [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]
  @type pid_set :: %{optional(pid()) => true}
  @spawn_trace_grace_ms 50

  defp extract_supervisor_strategy(supervisor) do
    state = :sys.get_state(supervisor)

    case state do
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.find(fn value -> value in @strategies end)

      _ ->
        nil
    end
  end

  defp linked_processes(pid) when is_pid(pid) do
    case Process.info(pid, :links) do
      {:links, links} ->
        Enum.filter(links, &is_pid/1)

      _ ->
        []
    end
  end

  defp capture_spawned_processes(operation_fun) do
    tracer = self()
    :erlang.trace(tracer, true, [:procs, :set_on_spawn])

    try do
      operation_fun.()
    after
      wait_for_spawn_trace_grace()
      :erlang.trace(tracer, false, [:procs, :set_on_spawn])
    end

    {spawned, traced} = drain_spawn_trace_messages(%{}, pid_set_put(%{}, tracer))
    disable_process_tracing(pid_set_to_list(traced))

    {spawned, _traced_after_disable} = drain_spawn_trace_messages(spawned, traced)
    pid_set_to_list(spawned)
  end

  defp wait_for_spawn_trace_grace do
    receive do
    after
      @spawn_trace_grace_ms -> :ok
    end
  end

  @spec drain_spawn_trace_messages(pid_set(), pid_set()) :: {pid_set(), pid_set()}
  defp drain_spawn_trace_messages(spawned_acc, traced_acc) do
    receive do
      {:trace, traced_pid, :spawn, spawned_pid, _mfa}
      when is_pid(traced_pid) and is_pid(spawned_pid) ->
        drain_spawn_trace_messages(
          pid_set_put(spawned_acc, spawned_pid),
          traced_acc |> pid_set_put(traced_pid) |> pid_set_put(spawned_pid)
        )

      {:trace, traced_pid, :spawned, spawned_pid, _mfa}
      when is_pid(traced_pid) and is_pid(spawned_pid) ->
        drain_spawn_trace_messages(
          pid_set_put(spawned_acc, spawned_pid),
          traced_acc |> pid_set_put(traced_pid) |> pid_set_put(spawned_pid)
        )

      {:trace, traced_pid, _event, _arg} when is_pid(traced_pid) ->
        drain_spawn_trace_messages(spawned_acc, pid_set_put(traced_acc, traced_pid))

      {:trace, traced_pid, _event, _arg1, _arg2} when is_pid(traced_pid) ->
        drain_spawn_trace_messages(spawned_acc, pid_set_put(traced_acc, traced_pid))

      {:trace, traced_pid, _event, _arg1, _arg2, _arg3} when is_pid(traced_pid) ->
        drain_spawn_trace_messages(spawned_acc, pid_set_put(traced_acc, traced_pid))
    after
      0 ->
        {spawned_acc, traced_acc}
    end
  end

  @spec pid_set_put(pid_set(), pid()) :: pid_set()
  defp pid_set_put(set, pid), do: Map.put(set, pid, true)

  @spec pid_set_to_list(pid_set()) :: [pid()]
  defp pid_set_to_list(set), do: Map.keys(set)

  defp disable_process_tracing(pids) do
    Enum.each(pids, fn pid ->
      if Process.alive?(pid) do
        try do
          :erlang.trace(pid, false, [:all])
        catch
          :error, _ -> :ok
        end
      end
    end)
  end

  defp persistent_process?(pid, wait_ms) do
    if Process.alive?(pid) do
      receive do
      after
        wait_ms -> :ok
      end

      Process.alive?(pid)
    else
      false
    end
  end

  defp reportable_process?(pid) do
    case Process.info(pid, [:initial_call]) do
      nil ->
        false

      info ->
        initial_call = Keyword.get(info, :initial_call, nil)
        is_tuple(initial_call)
    end
  end
end
