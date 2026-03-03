defmodule Supertester.Internal.SharedRegistry do
  @moduledoc false

  alias Supertester.Internal.Poller

  @registry_name :supertester_shared_registry
  @ready_timeout_ms 200
  @max_start_attempts 3

  @spec name() :: atom()
  def name, do: @registry_name

  @spec ensure_started() :: {:ok, pid()}
  def ensure_started do
    ensure_ready_registry(@max_start_attempts)
  end

  defp ensure_ready_registry(attempts_left) when attempts_left > 0 do
    with {:ok, pid} <- fetch_or_start_registry(),
         :ok <- await_registry_ready(pid) do
      {:ok, pid}
    else
      {:error, :not_ready} ->
        cleanup_stale_registry()
        ensure_ready_registry(attempts_left - 1)
    end
  end

  defp ensure_ready_registry(0) do
    cleanup_stale_registry()

    with {:ok, pid} <- start_registry(),
         :ok <- await_registry_ready(pid) do
      {:ok, pid}
    else
      {:error, :not_ready} ->
        raise "unable to start shared registry #{@registry_name} in a ready state"
    end
  end

  defp fetch_or_start_registry do
    case Process.whereis(@registry_name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_registry()
    end
  end

  defp await_registry_ready(pid) when is_pid(pid) do
    case Poller.until(fn -> registry_ready_probe(pid) end, @ready_timeout_ms, 5) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :not_ready}
      {:error, _} -> {:error, :not_ready}
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
    :error, _ ->
      :retry

    :exit, _ ->
      :retry
  end

  defp start_registry do
    cleanup_stale_partitions()

    case start_registry_once() do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        handle_start_error(reason)
    end
  end

  defp handle_start_error(reason) do
    if stale_partition_error?(reason) do
      cleanup_stale_partitions()

      case start_registry_once() do
        {:ok, pid} ->
          Process.unlink(pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, _reason} ->
          {:error, :not_ready}
      end
    else
      {:error, :not_ready}
    end
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

  defp cleanup_stale_registry do
    case Process.whereis(@registry_name) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        await_down(ref, pid, @ready_timeout_ms)

      _ ->
        :ok
    end

    cleanup_stale_partitions()
    :ok
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
        pid when is_pid(pid) ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)
          await_down(ref, pid, @ready_timeout_ms)

        _ ->
          :ok
      end
    end)
  end

  defp await_down(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush])
    end
  end
end
