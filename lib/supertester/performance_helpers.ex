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

  @default_memory_sample_count 12
  @default_min_absolute_growth_bytes 256_000
  @default_min_upward_ratio 0.6

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

    sample_count =
      normalize_sample_count(Keyword.get(opts, :sample_count, @default_memory_sample_count))

    warmup_iterations =
      normalize_warmup_iterations(
        Keyword.get(opts, :warmup_iterations, div(iterations, 10)),
        iterations
      )

    if warmup_iterations > 0 do
      Enum.each(1..warmup_iterations, fn _ -> operation.() end)
    end

    measured_iterations = max(iterations - warmup_iterations, 0)
    samples = collect_memory_samples(operation, measured_iterations, sample_count)

    case __analyze_memory_samples__(samples, threshold, opts) do
      :ok ->
        :ok

      {:leak, info} ->
        raise """
        Memory leak detected: growth rate #{Float.round(info.growth_rate * 100, 2)}% exceeds threshold #{Float.round(threshold * 100, 2)}%.

        Absolute growth: #{info.absolute_growth_bytes} bytes
        Upward trend ratio: #{Float.round(info.upward_ratio * 100, 2)}%
        Memory samples: #{inspect(info.samples)}
        """
    end

    :ok
  end

  @doc false
  @spec __analyze_memory_samples__([non_neg_integer()], float(), keyword()) ::
          :ok
          | {:leak,
             %{
               growth_rate: float(),
               absolute_growth_bytes: integer(),
               upward_ratio: float(),
               slope: float(),
               samples: [non_neg_integer()]
             }}
  def __analyze_memory_samples__(samples, threshold, opts \\ [])
      when is_list(samples) and is_float(threshold) do
    if length(samples) < 3 do
      :ok
    else
      min_absolute_growth =
        Keyword.get(opts, :min_absolute_growth_bytes, @default_min_absolute_growth_bytes)

      min_upward_ratio = Keyword.get(opts, :min_upward_ratio, @default_min_upward_ratio)

      baseline_window = baseline_window(samples)
      first_baseline = median_value(Enum.take(samples, baseline_window))
      last_baseline = median_value(Enum.take(samples, -baseline_window))
      absolute_growth = trunc(last_baseline - first_baseline)

      growth_rate =
        if first_baseline <= 0 do
          0.0
        else
          (last_baseline - first_baseline) / first_baseline
        end

      upward_ratio = upward_step_ratio(samples)
      slope = least_squares_slope(samples)
      normalized_slope = if first_baseline <= 0, do: 0.0, else: slope / first_baseline

      if growth_rate > threshold and absolute_growth >= min_absolute_growth and
           upward_ratio >= min_upward_ratio and normalized_slope > 0 do
        {:leak,
         %{
           growth_rate: growth_rate,
           absolute_growth_bytes: absolute_growth,
           upward_ratio: upward_ratio,
           slope: slope,
           samples: samples
         }}
      else
        :ok
      end
    end
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

    monitor_task =
      Task.async(fn ->
        monitor_mailbox(server, [initial_size], sampling_interval)
      end)

    {result, samples} =
      try do
        result = operation.()
        {result, stop_monitor_task(monitor_task)}
      catch
        kind, reason ->
          _ = stop_monitor_task(monitor_task)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {:message_queue_len, final_size} = Process.info(server, :message_queue_len)

    all_samples = samples ++ [final_size]
    max_size = Enum.max(all_samples)

    avg_size = Enum.sum(all_samples) / length(all_samples)

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

  defp collect_memory_samples(_operation, iterations, _sample_count) when iterations <= 0, do: []

  defp collect_memory_samples(operation, iterations, sample_count) do
    checkpoints = sample_checkpoints(iterations, sample_count)

    1..iterations
    |> Enum.reduce([], fn iteration, acc ->
      operation.()

      if MapSet.member?(checkpoints, iteration) do
        :erlang.garbage_collect()
        [:erlang.memory(:total) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp sample_checkpoints(iterations, sample_count) do
    effective_count = min(max(sample_count, 3), max(iterations, 1))

    1..effective_count
    |> Enum.map(fn point ->
      div(iterations * point + effective_count - 1, effective_count)
    end)
    |> MapSet.new()
  end

  defp normalize_sample_count(value) when is_integer(value), do: max(value, 3)
  defp normalize_sample_count(value) when is_float(value), do: max(trunc(value), 3)
  defp normalize_sample_count(_), do: @default_memory_sample_count

  defp normalize_warmup_iterations(value, iterations) when is_integer(value) do
    value
    |> max(0)
    |> min(max(iterations, 0))
  end

  defp normalize_warmup_iterations(value, iterations) when is_float(value) do
    value
    |> trunc()
    |> normalize_warmup_iterations(iterations)
  end

  defp normalize_warmup_iterations(_, iterations), do: normalize_warmup_iterations(0, iterations)

  defp baseline_window(samples) do
    sample_count = length(samples)
    max(1, min(3, div(sample_count, 2)))
  end

  defp median_value([]), do: 0.0

  defp median_value(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1 do
      sorted |> Enum.at(mid) |> Kernel.*(1.0)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  defp upward_step_ratio(samples) do
    pairs = Enum.zip(samples, tl(samples))
    upward_steps = Enum.count(pairs, fn {left, right} -> right > left end)
    upward_steps / max(length(pairs), 1)
  end

  defp least_squares_slope(samples) do
    count = length(samples)

    if count < 2 do
      0.0
    else
      x_mean = (count - 1) / 2.0
      y_mean = Enum.sum(samples) / count

      {covariance, variance} =
        samples
        |> Enum.with_index()
        |> Enum.reduce({0.0, 0.0}, fn {y, x}, {cov_acc, var_acc} ->
          x_delta = x - x_mean
          y_delta = y - y_mean
          {cov_acc + x_delta * y_delta, var_acc + x_delta * x_delta}
        end)

      if variance == 0.0, do: 0.0, else: covariance / variance
    end
  end

  defp monitor_mailbox(server, samples, interval) do
    receive do
      :stop ->
        samples
    after
      interval ->
        case Process.info(server, :message_queue_len) do
          {:message_queue_len, size} ->
            monitor_mailbox(server, [size | samples], interval)

          nil ->
            # Process died during monitoring
            samples
        end
    end
  end

  defp stop_monitor_task(task) do
    send(task.pid, :stop)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, samples} when is_list(samples) -> samples
      _ -> []
    end
  end
end
