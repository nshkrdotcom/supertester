defmodule Supertester.Internal.ProcessLifecycle do
  @moduledoc false

  @spec default_cleanup(term(), map()) :: :ok
  def default_cleanup(subject, _ctx) do
    if is_pid(subject) do
      stop_process_safely(subject)
    end

    :ok
  end

  @spec stop_process_safely(pid() | %{pid: pid()}, timeout()) :: :ok
  def stop_process_safely(process, timeout \\ 1000)

  def stop_process_safely(%{pid: pid}, timeout) when is_pid(pid) do
    stop_process_safely(pid, timeout)
  end

  def stop_process_safely(pid, timeout) when is_pid(pid) do
    if Process.alive?(pid) do
      # Cleanup should not be able to terminate the caller because of stale links.
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)
      await_shutdown_or_escalate(ref, pid, timeout)
    end

    :ok
  end

  @spec stop_genserver_safely(pid(), timeout()) :: :ok
  def stop_genserver_safely(pid, timeout \\ 1000) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, timeout)
      catch
        :exit, _ -> stop_process_safely(pid, timeout)
      end
    end

    :ok
  end

  @spec stop_supervisor_safely(pid(), timeout()) :: :ok
  def stop_supervisor_safely(pid, timeout \\ 1000) when is_pid(pid) do
    if Process.alive?(pid) do
      pid
      |> safe_supervisor_children()
      |> Enum.each(fn
        {_id, child_pid, _type, _modules} when is_pid(child_pid) ->
          stop_process_safely(child_pid, timeout)

        _ ->
          :ok
      end)

      try do
        Supervisor.stop(pid, :normal, timeout)
      catch
        :exit, _ -> stop_process_safely(pid, timeout)
      end
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

  defp safe_supervisor_children(supervisor) do
    Supervisor.which_children(supervisor)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
