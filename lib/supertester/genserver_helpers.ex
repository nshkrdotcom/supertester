defmodule Supertester.GenServerHelpers do
  @moduledoc """
  Specialized helpers for GenServer testing patterns.

  This module provides utilities specifically designed for testing GenServer behavior,
  including state management, concurrent testing, and error scenarios.

  ## Key Features

  - Safe GenServer state access
  - Cast and sync patterns for proper async operation testing
  - Concurrent testing utilities
  - Error testing and crash recovery
  - Timeout-aware GenServer operations

  ## Usage

      import Supertester.GenServerHelpers

      test "genserver state management" do
        {:ok, server} = setup_isolated_genserver(MyGenServer)
        state = get_server_state_safely(server)
        assert state.counter == 0
      end
  """

  @doc """
  Safely retrieves the internal state of a GenServer.

  This function attempts to get the GenServer state without causing crashes
  if the server is not responsive or doesn't support state inspection.

  ## Parameters

  - `server` - The GenServer pid or name

  ## Returns

  `{:ok, state}` if successful, `{:error, reason}` otherwise

  ## Example

      {:ok, state} = get_server_state_safely(my_server)
  """
  def get_server_state_safely(server) do
    try do
      # Try to get state via :sys.get_state/1 which works for most GenServers
      state = :sys.get_state(server)
      {:ok, state}
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Makes a GenServer call with timeout handling.

  ## Parameters

  - `server` - The GenServer pid or name
  - `message` - The message to send
  - `timeout` - Timeout in milliseconds (default: 1000)

  ## Returns

  `{:ok, response}` if successful, `{:error, reason}` otherwise

  ## Example

      {:ok, response} = call_with_timeout(server, :get_counter, 5000)
  """
  def call_with_timeout(server, message, timeout \\ 1000) do
    try do
      response = GenServer.call(server, message, timeout)
      {:ok, response}
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Sends a cast and then synchronizes with a sync message.

  This is crucial for testing async operations - it ensures the cast has been
  processed before the test continues.

  ## Parameters

  - `server` - The GenServer pid or name
  - `cast_message` - The async message to cast
  - `sync_message` - The sync message for synchronization (default: :__supertester_sync__)

  ## Returns

  `:ok` if successful, `{:error, reason}` otherwise

  ## Example

      :ok = cast_and_sync(server, {:increment, 5})
      {:ok, state} = get_server_state_safely(server)
      assert state.counter == 5
  """
  def cast_and_sync(server, cast_message, sync_message \\ :__supertester_sync__) do
    try do
      :ok = GenServer.cast(server, cast_message)

      # Synchronize to ensure cast was processed
      case GenServer.call(server, sync_message, 1000) do
        :ok -> :ok
        # Server doesn't handle sync message, but cast likely processed
        {:error, :unknown_call} -> :ok
        response -> {:ok, response}
      end
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Performs concurrent calls to a GenServer for stress testing.

  ## Parameters

  - `server` - The GenServer pid or name
  - `calls` - List of messages to send concurrently
  - `count` - Number of concurrent processes per message (default: 10)

  ## Returns

  `{:ok, results}` with list of {call, result} tuples

  ## Example

      calls = [:get_counter, {:increment, 1}, :get_counter]
      {:ok, results} = concurrent_calls(server, calls, 5)
  """
  def concurrent_calls(server, calls, count \\ 10) do
    tasks =
      for call <- calls,
          _i <- 1..count do
        Task.async(fn ->
          case call_with_timeout(server, call, 5000) do
            {:ok, result} -> {call, {:ok, result}}
            error -> {call, error}
          end
        end)
      end

    results =
      tasks
      |> Task.await_many(10_000)
      |> Enum.group_by(fn {call, _result} -> call end)
      |> Enum.map(fn {call, results} ->
        {call, Enum.map(results, fn {_call, result} -> result end)}
      end)

    {:ok, results}
  end

  @doc """
  Performs stress testing on a GenServer with various operations.

  ## Parameters

  - `server` - The GenServer pid or name
  - `operations` - List of operations to perform randomly
  - `duration` - Duration in milliseconds (default: 5000)

  ## Returns

  `{:ok, stats}` with stress test statistics

  ## Example

      operations = [
        {:call, :get_counter},
        {:cast, {:increment, 1}},
        {:call, {:add, 5}}
      ]
      {:ok, stats} = stress_test_server(server, operations, 10_000)
  """
  def stress_test_server(server, operations, duration \\ 5000) do
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration

    parent = self()

    # Start multiple workers
    workers =
      for _i <- 1..5 do
        spawn_link(fn ->
          stress_worker(server, operations, end_time, parent, 0, 0, 0)
        end)
      end

    # Collect results
    stats = collect_stress_results(workers, %{calls: 0, casts: 0, errors: 0})

    {:ok, stats}
  end

  @doc """
  Tests GenServer crash recovery behavior.

  ## Parameters

  - `server` - The GenServer pid or name
  - `crash_reason` - The reason to crash the server with

  ## Returns

  `{:ok, recovery_info}` if recovery successful, `{:error, reason}` otherwise

  ## Example

      {:ok, info} = test_server_crash_recovery(server, :test_crash)
      assert info.recovered == true
  """
  def test_server_crash_recovery(server, crash_reason) do
    # Get original PID
    original_pid =
      case server do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    if original_pid == nil do
      {:error, :server_not_found}
    else
      # Monitor the original process
      ref = Process.monitor(original_pid)

      # Crash the server
      Process.exit(original_pid, crash_reason)

      # Wait for crash
      crash_confirmed =
        receive do
          {:DOWN, ^ref, :process, ^original_pid, ^crash_reason} -> true
          {:DOWN, ^ref, :process, ^original_pid, _other_reason} -> true
        after
          1000 -> false
        end

      if crash_confirmed do
        # Wait for potential restart (if supervised)
        case wait_for_recovery(server, original_pid, 5000) do
          {:ok, new_pid} ->
            {:ok,
             %{
               recovered: true,
               original_pid: original_pid,
               new_pid: new_pid,
               crash_reason: crash_reason
             }}

          {:error, reason} ->
            {:ok,
             %{
               recovered: false,
               original_pid: original_pid,
               new_pid: nil,
               crash_reason: crash_reason,
               recovery_error: reason
             }}
        end
      else
        {:error, :crash_failed}
      end
    end
  end

  @doc """
  Tests how a GenServer handles invalid messages.

  ## Parameters

  - `server` - The GenServer pid or name
  - `invalid_messages` - List of invalid messages to test

  ## Returns

  `{:ok, results}` with test results for each message

  ## Example

      invalid_messages = [:invalid_call, {:unknown, :message}, "string_message"]
      {:ok, results} = test_invalid_messages(server, invalid_messages)
  """
  def test_invalid_messages(server, invalid_messages) do
    results =
      Enum.map(invalid_messages, fn message ->
        result =
          case call_with_timeout(server, message, 1000) do
            {:ok, response} -> {:handled, response}
            {:error, reason} -> {:error, reason}
          end

        {message, result}
      end)

    {:ok, results}
  end

  # Private functions

  defp stress_worker(server, operations, end_time, parent, calls, casts, errors) do
    current_time = System.monotonic_time(:millisecond)

    if current_time < end_time do
      operation = Enum.random(operations)

      {new_calls, new_casts, new_errors} =
        case operation do
          {:call, message} ->
            case call_with_timeout(server, message, 100) do
              {:ok, _} -> {calls + 1, casts, errors}
              {:error, _} -> {calls, casts, errors + 1}
            end

          {:cast, message} ->
            # GenServer.cast always returns :ok
            GenServer.cast(server, message)
            {calls, casts + 1, errors}
        end

      stress_worker(server, operations, end_time, parent, new_calls, new_casts, new_errors)
    else
      send(parent, {:stress_result, self(), %{calls: calls, casts: casts, errors: errors}})
    end
  end

  defp collect_stress_results([], acc), do: acc

  defp collect_stress_results(workers, acc) do
    receive do
      {:stress_result, worker_pid, stats} ->
        updated_acc = %{
          calls: acc.calls + stats.calls,
          casts: acc.casts + stats.casts,
          errors: acc.errors + stats.errors
        }

        remaining_workers = List.delete(workers, worker_pid)
        collect_stress_results(remaining_workers, updated_acc)
    after
      5000 ->
        # Timeout waiting for workers
        acc
    end
  end

  defp wait_for_recovery(server, original_pid, timeout) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_recovery_loop(server, original_pid, start_time, timeout)
  end

  defp wait_for_recovery_loop(server, original_pid, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time > timeout do
      {:error, :recovery_timeout}
    else
      current_pid =
        case server do
          pid when is_pid(pid) -> pid
          name when is_atom(name) -> Process.whereis(name)
        end

      cond do
        current_pid == nil ->
          Process.sleep(10)
          wait_for_recovery_loop(server, original_pid, start_time, timeout)

        current_pid == original_pid ->
          Process.sleep(10)
          wait_for_recovery_loop(server, original_pid, start_time, timeout)

        current_pid != original_pid ->
          # New process found, verify it's responsive
          case call_with_timeout(current_pid, :__supertester_sync__, 100) do
            {:ok, _} ->
              {:ok, current_pid}

            {:error, _} ->
              Process.sleep(10)
              wait_for_recovery_loop(server, original_pid, start_time, timeout)
          end
      end
    end
  end
end
