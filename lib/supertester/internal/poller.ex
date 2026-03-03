defmodule Supertester.Internal.Poller do
  @moduledoc false

  @spec until((-> :ok | :retry | {:ok, term()} | {:error, term()}), timeout(), pos_integer()) ::
          :ok | {:ok, term()} | {:error, term()}
  def until(check_fun, timeout, interval_ms \\ 10)
      when is_function(check_fun, 0) and is_integer(timeout) and timeout >= 0 and
             is_integer(interval_ms) and interval_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_until(check_fun, deadline, interval_ms)
  end

  defp do_until(check_fun, deadline, interval_ms) do
    case check_fun.() do
      :ok ->
        :ok

      {:ok, _} = ok ->
        ok

      :retry ->
        wait_and_retry(check_fun, deadline, interval_ms)

      {:error, _} = error ->
        error

      _other ->
        wait_and_retry(check_fun, deadline, interval_ms)
    end
  end

  defp wait_and_retry(check_fun, deadline, interval_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
      after
        min(interval_ms, remaining) -> :ok
      end

      do_until(check_fun, deadline, interval_ms)
    end
  end
end
