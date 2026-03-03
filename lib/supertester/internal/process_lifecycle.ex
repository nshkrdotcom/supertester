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
      Process.exit(pid, :shutdown)
      await_shutdown_or_escalate(ref, pid, timeout)
    end

    :ok
  end

  defp await_shutdown_or_escalate(ref, pid, timeout) do
    case await_down(ref, pid, timeout) do
      true -> :ok
      false -> force_kill_and_drain(ref, pid, timeout)
    end
  end

  defp force_kill_and_drain(ref, pid, timeout) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    await_down(ref, pid, min(timeout, 100))
    Process.demonitor(ref, [:flush])
  end

  defp await_down(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        true
    after
      timeout ->
        false
    end
  end
end
