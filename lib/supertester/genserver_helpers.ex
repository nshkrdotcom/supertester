defmodule Supertester.GenServerHelpers do
  require Logger

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
  @spec get_server_state_safely(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def get_server_state_safely(server) do
    # Try to get state via :sys.get_state/1 which works for most GenServers
    state = :sys.get_state(server)
    {:ok, state}
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
    error -> {:error, error}
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
  @spec call_with_timeout(GenServer.server(), term(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def call_with_timeout(server, message, timeout \\ 1000) do
    response = GenServer.call(server, message, timeout)
    {:ok, response}
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
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
  @spec cast_and_sync(GenServer.server(), term(), term(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def cast_and_sync(server, cast_message, sync_message \\ :__supertester_sync__, opts \\ []) do
    strict? = Keyword.get(opts, :strict?, false)
    sync_timeout = Keyword.get(opts, :timeout, 1000)

    try do
      :ok = GenServer.cast(server, cast_message)

      # Synchronize to ensure cast was processed
      case GenServer.call(server, sync_message, sync_timeout) do
        :ok ->
          :ok

        {:error, :unknown_call} ->
          handle_missing_sync(strict?, server, sync_message)

        response ->
          {:ok, response}
      end
    catch
      :exit, {:noproc, _} ->
        {:error, :noproc}

      :exit, {:timeout, _} ->
        {:error, :timeout}

      :exit, reason ->
        if missing_sync_exit?(reason, sync_message) do
          handle_missing_sync(strict?, server, sync_message)
        else
          {:error, reason}
        end
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
  @spec concurrent_calls(GenServer.server(), [term()], pos_integer(), keyword()) ::
          {:ok, [map()]}
  def concurrent_calls(server, calls, count \\ 10, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    initial =
      Enum.reduce(calls, %{}, fn call, acc ->
        Map.put(acc, call, %{call: call, successes: [], errors: []})
      end)

    tasks =
      for call <- calls,
          _ <- 1..count do
        Task.async(fn ->
          case call_with_timeout(server, call, timeout) do
            {:ok, response} -> {:ok, call, response}
            {:error, reason} -> {:error, call, reason}
          end
        end)
      end

    aggregated =
      tasks
      |> Task.await_many(timeout + 1_000)
      |> Enum.reduce(initial, fn
        {:ok, call, response}, acc ->
          update_in(acc, [call, :successes], fn successes -> [response | successes] end)

        {:error, call, reason}, acc ->
          update_in(acc, [call, :errors], fn errors -> [reason | errors] end)
      end)

    ordered =
      calls
      |> Enum.uniq()
      |> Enum.map(fn call ->
        entry = Map.fetch!(aggregated, call)

        %{
          call: entry.call,
          successes: Enum.reverse(entry.successes),
          errors: Enum.reverse(entry.errors)
        }
      end)

    {:ok, ordered}
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
  @spec stress_test_server(GenServer.server(), [term()], pos_integer(), keyword()) ::
          {:ok,
           %{
             calls: non_neg_integer,
             casts: non_neg_integer,
             errors: non_neg_integer,
             duration_ms: non_neg_integer
           }}
  def stress_test_server(server, operations, duration \\ 5000, opts \\ []) do
    worker_count = Keyword.get(opts, :workers, 5)
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration

    tasks =
      for _ <- 1..worker_count do
        Task.async(fn -> stress_worker(server, operations, end_time, 0, 0, 0) end)
      end

    stats =
      tasks
      |> Enum.reduce(%{calls: 0, casts: 0, errors: 0}, fn task, acc ->
        worker_stats = Task.await(task, duration + 1_000)

        %{
          calls: acc.calls + worker_stats.calls,
          casts: acc.casts + worker_stats.casts,
          errors: acc.errors + worker_stats.errors
        }
      end)

    duration_ms = max(System.monotonic_time(:millisecond) - start_time, 0)

    {:ok, Map.put(stats, :duration_ms, duration_ms)}
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
  @spec test_server_crash_recovery(GenServer.server(), term()) :: {:ok, map()} | {:error, term()}
  def test_server_crash_recovery(server, crash_reason) do
    original_pid = resolve_server_pid(server)

    if original_pid == nil do
      {:error, :server_not_found}
    else
      do_crash_recovery_test(server, original_pid, crash_reason)
    end
  end

  defp resolve_server_pid(pid) when is_pid(pid), do: pid
  defp resolve_server_pid(name) when is_atom(name), do: Process.whereis(name)

  defp do_crash_recovery_test(server, original_pid, crash_reason) do
    ref = Process.monitor(original_pid)
    Process.exit(original_pid, crash_reason)

    crash_confirmed = await_crash_confirmation(ref, original_pid, crash_reason)

    if crash_confirmed do
      build_recovery_result(server, original_pid, crash_reason)
    else
      {:error, :crash_failed}
    end
  end

  defp await_crash_confirmation(ref, original_pid, _crash_reason) do
    receive do
      {:DOWN, ^ref, :process, ^original_pid, _reason} -> true
    after
      1000 -> false
    end
  end

  defp build_recovery_result(server, original_pid, crash_reason) do
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
  @spec test_invalid_messages(GenServer.server(), [term()]) :: {:ok, [{term(), term()}]}
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

  defp stress_worker(server, operations, end_time, calls, casts, errors) do
    current_time = System.monotonic_time(:millisecond)

    if current_time < end_time do
      operation = Enum.random(operations)

      {new_calls, new_casts, new_errors} =
        execute_stress_operation(server, operation, calls, casts, errors)

      stress_worker(server, operations, end_time, new_calls, new_casts, new_errors)
    else
      %{calls: calls, casts: casts, errors: errors}
    end
  end

  defp execute_stress_operation(server, {:call, message}, calls, casts, errors) do
    case call_with_timeout(server, message, 100) do
      {:ok, _} -> {calls + 1, casts, errors}
      {:error, _} -> {calls, casts, errors + 1}
    end
  end

  defp execute_stress_operation(server, {:cast, message}, calls, casts, errors) do
    # GenServer.cast always returns :ok
    GenServer.cast(server, message)
    {calls, casts + 1, errors}
  end

  defp wait_for_recovery(server, original_pid, timeout) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_recovery_loop(server, original_pid, start_time, timeout)
  end

  defp wait_for_recovery_loop(server, original_pid, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    remaining = timeout - (current_time - start_time)

    if remaining <= 0 do
      {:error, :recovery_timeout}
    else
      current_pid = resolve_server_pid(server)
      check_recovery_status(server, original_pid, current_pid, remaining, start_time, timeout)
    end
  end

  defp check_recovery_status(server, original_pid, nil, remaining, start_time, timeout) do
    wait_and_retry_recovery(server, original_pid, remaining, start_time, timeout)
  end

  defp check_recovery_status(server, original_pid, current_pid, remaining, start_time, timeout)
       when current_pid == original_pid do
    wait_and_retry_recovery(server, original_pid, remaining, start_time, timeout)
  end

  defp check_recovery_status(server, original_pid, current_pid, remaining, start_time, timeout) do
    case call_with_timeout(current_pid, :__supertester_sync__, 100) do
      {:ok, _} ->
        {:ok, current_pid}

      {:error, _} ->
        wait_and_retry_recovery(server, original_pid, remaining, start_time, timeout)
    end
  end

  defp wait_and_retry_recovery(server, original_pid, remaining, start_time, timeout) do
    receive do
    after
      min(10, remaining) -> :ok
    end

    wait_for_recovery_loop(server, original_pid, start_time, timeout)
  end

  defp handle_missing_sync(true, server, sync_message) do
    raise ArgumentError,
          "GenServer #{inspect(server)} must handle #{inspect(sync_message)} to use cast_and_sync/4 in strict mode"
  end

  defp handle_missing_sync(false, server, sync_message) do
    Logger.debug(fn ->
      "GenServer #{inspect(server)} ignored sync message #{inspect(sync_message)}; assuming cast completed"
    end)

    :ok
  end

  defp missing_sync_exit?(%RuntimeError{message: message}, sync_message) do
    contains_sync_message?(message, sync_message)
  end

  defp missing_sync_exit?({{%RuntimeError{message: message}, _stack}, _call_info}, sync_message) do
    contains_sync_message?(message, sync_message)
  end

  defp missing_sync_exit?(_, _), do: false

  defp contains_sync_message?(message, _sync_message) do
    String.contains?(message, "handle_call")
  end
end
