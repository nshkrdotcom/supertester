defmodule Supertester.Internal.Chaos.SuiteRunner do
  @moduledoc false

  @type scenario_result :: {:ok, map()} | {:error, {map(), term()}}

  @spec run(
          term(),
          [map()],
          :infinity | non_neg_integer(),
          (term(), map() -> scenario_result()),
          term()
        ) ::
          {[scenario_result()], [map()]}
  def run(target, scenarios, timeout, execute_fun, timeout_marker)
      when is_list(scenarios) and is_function(execute_fun, 2) do
    suite_start = System.monotonic_time(:millisecond)
    do_run(target, scenarios, suite_start, timeout, execute_fun, timeout_marker, [])
  end

  defp do_run(_target, [], _suite_start, _timeout, _execute_fun, _timeout_marker, acc) do
    {Enum.reverse(acc), []}
  end

  defp do_run(target, [scenario | rest], suite_start, timeout, execute_fun, timeout_marker, acc) do
    case remaining_timeout_ms(suite_start, timeout) do
      remaining when is_integer(remaining) and remaining <= 0 ->
        {Enum.reverse(acc), [scenario | rest]}

      :infinity ->
        result = execute_fun.(target, scenario)
        do_run(target, rest, suite_start, timeout, execute_fun, timeout_marker, [result | acc])

      remaining ->
        result = execute_with_timeout(target, scenario, remaining, execute_fun, timeout_marker)

        case result do
          {:error, {^scenario, ^timeout_marker}} ->
            timeout_result = {:error, {scenario, :timeout}}
            {Enum.reverse([timeout_result | acc]), rest}

          _ ->
            do_run(target, rest, suite_start, timeout, execute_fun, timeout_marker, [result | acc])
        end
    end
  end

  defp execute_with_timeout(target, scenario, timeout_ms, execute_fun, timeout_marker)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> execute_fun.(target, scenario) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {scenario, reason}}

      nil ->
        {:error, {scenario, timeout_marker}}
    end
  end

  defp remaining_timeout_ms(_suite_start, :infinity), do: :infinity

  defp remaining_timeout_ms(suite_start, timeout_ms) when is_integer(timeout_ms) do
    elapsed = System.monotonic_time(:millisecond) - suite_start
    max(timeout_ms - elapsed, 0)
  end
end
