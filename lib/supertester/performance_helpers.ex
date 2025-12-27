defmodule Supertester.PerformanceHelpers do
  @moduledoc """
  Performance testing and regression detection for OTP systems.

  Integrates performance measurement with Supertester's isolation patterns and provides
  performance assertions for CI/CD pipelines.

  ## Key Features

  - Performance assertions (max time, memory, reductions)
  - Memory leak detection
  - Mailbox growth monitoring
  - Operation measurement and comparison

  ## Usage

      import Supertester.PerformanceHelpers

      test "critical path performance" do
        assert_performance(
          fn -> CriticalServer.operation(server) end,
          max_time_ms: 100,
          max_memory_bytes: 1_000_000
        )
      end
  """

  @doc """
  Asserts operation meets performance expectations.

  ## Expectations

  - `:max_time_ms` - Maximum execution time in milliseconds
  - `:max_memory_bytes` - Maximum memory consumption in bytes
  - `:max_reductions` - Maximum reductions (CPU work)

  ## Examples

      assert_performance(
        fn -> expensive_operation() end,
        max_time_ms: 100,
        max_memory_bytes: 500_000,
        max_reductions: 100_000
      )
  """
  @spec assert_performance((-> any()), keyword()) :: :ok
  def assert_performance(operation, expectations) when is_function(operation, 0) do
    operation
    |> measure_operation()
    |> assert_expectations(expectations)
  end

  @doc """
  Asserts that the provided measurement map meets the expectations.
  """
  @spec assert_expectations(map(), keyword()) :: :ok
  def assert_expectations(measurements, expectations) when is_map(measurements) do
    Enum.each(expectations, &assert_expectation(measurements, &1))
    :ok
  end

  defp assert_expectation(measurements, {:max_time_ms, expected_value}) do
    actual_ms = measurements.time_us / 1000.0

    if actual_ms > expected_value do
      raise "Execution time #{Float.round(actual_ms, 2)}ms exceeded maximum of #{expected_value}ms"
    end
  end

  defp assert_expectation(measurements, {:max_memory_bytes, expected_value}) do
    if measurements.memory_bytes > expected_value do
      raise "Memory usage #{measurements.memory_bytes} bytes exceeded maximum of #{expected_value} bytes"
    end
  end

  defp assert_expectation(measurements, {:max_reductions, expected_value}) do
    if measurements.reductions > expected_value do
      raise "Reductions #{measurements.reductions} exceeded maximum of #{expected_value}"
    end
  end

  defp assert_expectation(_measurements, _other), do: :ok

  @doc """
  Verifies operation doesn't leak memory over many iterations.

  ## Parameters

  - `iterations` - Number of times to run the operation
  - `operation` - Function to execute
  - `opts` - Options (`:threshold` for acceptable growth rate, default: 0.1 = 10%)

  ## Examples

      assert_no_memory_leak(10_000, fn ->
        handle_message(server, message())
      end)
  """
  @spec assert_no_memory_leak(pos_integer(), (-> any()), keyword()) :: :ok
  def assert_no_memory_leak(iterations, operation, opts \\ [])
      when is_function(operation, 0) and is_integer(iterations) do
    threshold = Keyword.get(opts, :threshold, 0.1)

    # Take memory samples at different points
    sample_points = [
      trunc(iterations * 0.1),
      trunc(iterations * 0.3),
      trunc(iterations * 0.5),
      trunc(iterations * 0.7),
      trunc(iterations * 0.9)
    ]

    samples = collect_memory_samples(operation, iterations, sample_points, [])

    # Check for memory trend
    if length(samples) >= 3 do
      growth_rate = calculate_growth_rate(samples)

      if growth_rate > threshold do
        raise """
        Memory leak detected: growth rate #{Float.round(growth_rate * 100, 2)}% exceeds threshold #{Float.round(threshold * 100, 2)}%.

        Memory samples: #{inspect(samples)}
        """
      end
    end

    :ok
  end

  @doc """
  Measures operation performance metrics.

  ## Returns

  Map with:
  - `:time_us` - Execution time in microseconds
  - `:memory_bytes` - Memory used in bytes
  - `:reductions` - Reductions (CPU work)
  - `:result` - Operation result

  ## Examples

      metrics = measure_operation(fn -> complex_calculation() end)
      IO.puts "Time: \#{metrics.time_us}μs, Memory: \#{metrics.memory_bytes} bytes"
  """
  @spec measure_operation((-> any())) :: map()
  def measure_operation(operation) when is_function(operation, 0) do
    # Force GC before measurement
    :erlang.garbage_collect()

    initial_memory = :erlang.memory(:total)
    {:reductions, reductions_before} = Process.info(self(), :reductions)

    {time_us, result} = :timer.tc(operation)

    {:reductions, reductions_after} = Process.info(self(), :reductions)
    final_memory = :erlang.memory(:total)

    %{
      time_us: time_us,
      memory_bytes: max(0, final_memory - initial_memory),
      reductions: reductions_after - reductions_before,
      result: result
    }
  end

  @doc """
  Measures mailbox growth during operation.

  ## Parameters

  - `server` - The GenServer PID to monitor
  - `operation` - Function to execute while monitoring

  ## Options

  - `:sampling_interval` - Interval in ms between mailbox samples (default: 10)

  ## Returns

  Map with:
  - `:initial_size` - Mailbox size before operation
  - `:final_size` - Mailbox size after operation
  - `:max_size` - Maximum mailbox size observed
  - `:avg_size` - Average mailbox size
  - `:result` - The result returned by the wrapped operation

  ## Examples

      report = measure_mailbox_growth(server, fn ->
        send_many_messages(server, 1000)
      end)

      assert report.max_size < 100
  """
  @spec measure_mailbox_growth(pid(), (-> any()), keyword()) :: map()
  def measure_mailbox_growth(server, operation, opts \\ [])
      when is_pid(server) and is_function(operation, 0) do
    {:message_queue_len, initial_size} = Process.info(server, :message_queue_len)
    sampling_interval = Keyword.get(opts, :sampling_interval, 10)

    # Start monitoring task
    parent = self()

    monitor_task =
      Task.async(fn ->
        monitor_mailbox(server, parent, [initial_size], sampling_interval)
      end)

    # Run operation
    result = operation.()

    # Stop monitoring
    send(monitor_task.pid, :stop)
    samples = Task.await(monitor_task, 5000)

    {:message_queue_len, final_size} = Process.info(server, :message_queue_len)

    all_samples = samples ++ [final_size]
    max_size = Enum.max(all_samples)

    avg_size =
      if length(all_samples) > 0 do
        Enum.sum(all_samples) / length(all_samples)
      else
        0
      end

    %{
      initial_size: initial_size,
      final_size: final_size,
      max_size: max_size,
      avg_size: avg_size,
      result: result
    }
  end

  @doc """
  Asserts GenServer mailbox remains stable during operation.

  ## Options

  - `:during` - Function to execute while monitoring (required)
  - `:max_size` - Maximum mailbox size allowed (default: 100)
  - Additional options forwarded to `measure_mailbox_growth/3`

  ## Examples

      assert_mailbox_stable(server,
        during: fn ->
          perform_operations(server, 1000)
        end,
        max_size: 50
      )
  """
  @spec assert_mailbox_stable(pid(), keyword()) :: :ok
  def assert_mailbox_stable(server, opts) when is_pid(server) do
    operation = Keyword.fetch!(opts, :during)
    max_size = Keyword.get(opts, :max_size, 100)
    monitor_opts = Keyword.drop(opts, [:during, :max_size])

    report = measure_mailbox_growth(server, operation, monitor_opts)

    if report.max_size > max_size do
      raise """
      Mailbox size exceeded maximum: #{report.max_size} > #{max_size}

      Initial: #{report.initial_size}
      Final: #{report.final_size}
      Max: #{report.max_size}
      Average: #{Float.round(report.avg_size, 2)}
      """
    end

    :ok
  end

  @doc """
  Compares performance of multiple functions.

  ## Parameters

  - `functions` - Map of function name to function

  ## Returns

  Map of function name to performance metrics

  ## Examples

      results = compare_performance(%{
        "approach_a" => fn -> approach_a() end,
        "approach_b" => fn -> approach_b() end
      })

      # Find fastest
      fastest = Enum.min_by(results, fn {_name, metrics} -> metrics.time_us end)
  """
  @spec compare_performance(map()) :: map()
  def compare_performance(functions) when is_map(functions) do
    Map.new(functions, fn {name, func} ->
      {name, measure_operation(func)}
    end)
  end

  # Private functions

  defp collect_memory_samples(_operation, 0, _sample_points, samples) do
    Enum.reverse(samples)
  end

  defp collect_memory_samples(operation, current, sample_points, samples) when current > 0 do
    operation.()

    new_current = current - 1

    # Check if we should take a sample
    new_samples =
      if new_current in sample_points do
        :erlang.garbage_collect()
        memory = :erlang.memory(:total)
        [memory | samples]
      else
        samples
      end

    collect_memory_samples(operation, new_current, sample_points, new_samples)
  end

  defp calculate_growth_rate(samples) do
    if length(samples) < 2 do
      0.0
    else
      first = hd(samples)
      last = List.last(samples)

      if first == 0 do
        0.0
      else
        (last - first) / first
      end
    end
  end

  defp monitor_mailbox(server, parent, samples, interval) do
    receive do
      :stop ->
        send(parent, {:samples, samples})
        samples
    after
      interval ->
        {:message_queue_len, size} = Process.info(server, :message_queue_len)
        monitor_mailbox(server, parent, [size | samples], interval)
    end
  end
end
