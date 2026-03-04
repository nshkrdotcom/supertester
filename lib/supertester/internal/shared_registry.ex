defmodule Supertester.Internal.SharedRegistry do
  @moduledoc false

  alias Supertester.Internal.{Poller, ProcessWatch}

  @registry_name :supertester_shared_registry
  @ready_timeout_ms 200
  @start_lock {:supertester, :shared_registry_start_lock}

  @spec name() :: atom()
  def name, do: @registry_name

  @spec ensure_started() :: {:ok, pid()}
  def ensure_started do
    :global.trans(@start_lock, fn ->
      ensure_started_locked()
    end)
  end

  defp ensure_started_locked do
    case Process.whereis(@registry_name) do
      pid when is_pid(pid) ->
        case await_registry_ready(pid) do
          :ok ->
            {:ok, pid}

          {:error, :not_ready} ->
            terminate_process(pid, @ready_timeout_ms)
            start_or_reuse_registry()
        end

      nil ->
        start_or_reuse_registry()
    end
  end

  defp start_or_reuse_registry do
    case start_registry_once() do
      {:ok, pid} ->
        Process.unlink(pid)
        await_registry_ready_or_raise(pid)

      {:error, {:already_started, pid}} ->
        await_registry_ready_or_raise(pid)

      {:error, reason} ->
        if stale_partition_error?(reason) do
          cleanup_stale_partitions()
          retry_start_registry()
        else
          raise "unable to start shared registry #{@registry_name}: #{inspect(reason)}"
        end
    end
  end

  defp retry_start_registry do
    case start_registry_once() do
      {:ok, pid} ->
        Process.unlink(pid)
        await_registry_ready_or_raise(pid)

      {:error, {:already_started, pid}} ->
        await_registry_ready_or_raise(pid)

      {:error, reason} ->
        raise "unable to start shared registry #{@registry_name}: #{inspect(reason)}"
    end
  end

  defp await_registry_ready_or_raise(pid) when is_pid(pid) do
    case await_registry_ready(pid) do
      :ok ->
        {:ok, pid}

      {:error, :not_ready} ->
        raise "unable to start shared registry #{@registry_name} in a ready state"
    end
  end

  defp await_registry_ready(pid) when is_pid(pid) do
    case Poller.until(fn -> registry_ready_probe(pid) end, @ready_timeout_ms, 5) do
      :ok -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp registry_ready_probe(pid) do
    cond do
      not Process.alive?(pid) ->
        :retry

      :ets.whereis(@registry_name) == :undefined ->
        :retry

      true ->
        # Registry.lookup/2 forces the same internal code path used by :via names.
        _ = Registry.lookup(@registry_name, :__supertester_probe__)
        :ok
    end
  catch
    :error, _ -> :retry
    :exit, _ -> :retry
  end

  defp start_registry_once do
    previous_flag = Process.flag(:trap_exit, true)

    try do
      Registry.start_link(keys: :unique, name: @registry_name)
    catch
      :exit, reason -> {:error, reason}
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  defp stale_partition_error?(
         {:shutdown, {:failed_to_start_child, child, {:already_started, _pid}}}
       )
       when is_atom(child) do
    partition_child_name?(child)
  end

  defp stale_partition_error?({:failed_to_start_child, child, {:already_started, _pid}})
       when is_atom(child) do
    partition_child_name?(child)
  end

  defp stale_partition_error?(_), do: false

  defp partition_child_name?(child_name) do
    child_name
    |> Atom.to_string()
    |> String.contains?("#{@registry_name}.PIDPartition")
  end

  defp cleanup_stale_partitions do
    partition_token = "#{@registry_name}.PIDPartition"

    Process.registered()
    |> Enum.filter(fn name ->
      name
      |> Atom.to_string()
      |> String.contains?(partition_token)
    end)
    |> Enum.each(fn name ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> terminate_process(pid, @ready_timeout_ms)
        _ -> :ok
      end
    end)

    :ok
  end

  defp terminate_process(pid, timeout) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      await_down(ref, pid, timeout)
    end

    :ok
  end

  defp await_down(ref, pid, timeout) do
    case ProcessWatch.await_down(ref, pid, timeout) do
      {:down, _reason} -> :ok
      :timeout -> :ok
    end
  end
end
