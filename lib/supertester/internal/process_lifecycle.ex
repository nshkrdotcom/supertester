defmodule Supertester.Internal.ProcessLifecycle do
  @moduledoc false

  @spec stop_process_safely(pid() | %{pid: pid()}, timeout()) :: :ok
  def stop_process_safely(process, timeout \\ 1000)

  def stop_process_safely(%{pid: pid}, timeout) when is_pid(pid) do
    stop_process_safely(pid, timeout)
  end

  def stop_process_safely(pid, timeout) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :normal)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
      end
    end

    :ok
  end
end
