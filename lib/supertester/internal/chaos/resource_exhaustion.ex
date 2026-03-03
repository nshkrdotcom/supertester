defmodule Supertester.Internal.Chaos.ResourceExhaustion do
  @moduledoc false

  @spec simulate(atom(), keyword()) :: {:ok, (-> :ok)} | {:error, term()}
  def simulate(resource, opts \\ [])

  def simulate(:process_limit, opts) do
    spawn_count = get_process_spawn_count(opts)
    spawned = spawn_resource_processes(spawn_count)
    cleanup_fn = build_process_cleanup_fn(spawned)
    {:ok, cleanup_fn}
  end

  def simulate(:ets_tables, opts) do
    count =
      opts
      |> Keyword.get(:count, 50)
      |> normalize_non_neg_count()

    tables =
      if count > 0 do
        for _ <- 1..count do
          :ets.new(:supertester_chaos_table, [:set, :public])
        end
      else
        []
      end

    cleanup_fn = fn ->
      Enum.each(tables, fn table ->
        try do
          :ets.delete(table)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    {:ok, cleanup_fn}
  end

  def simulate(:memory, opts) do
    size_mb = Keyword.get(opts, :size_mb, 10)
    bytes = size_mb * 1024 * 1024

    pid =
      spawn(fn ->
        _data = :binary.copy(<<0>>, bytes)

        receive do
          :stop -> :ok
        after
          60_000 -> :ok
        end
      end)

    cleanup_fn = fn ->
      if Process.alive?(pid) do
        send(pid, :stop)
      end

      :ok
    end

    {:ok, cleanup_fn}
  end

  def simulate(_resource, _opts) do
    {:error, :unsupported_resource}
  end

  defp get_process_spawn_count(opts) do
    case Keyword.get(opts, :spawn_count) do
      nil ->
        percentage = Keyword.get(opts, :percentage, 0.05)
        max(trunc(10_000 * percentage), 0)

      count ->
        normalize_non_neg_count(count)
    end
  end

  defp normalize_non_neg_count(value) when is_integer(value), do: max(value, 0)
  defp normalize_non_neg_count(value) when is_float(value), do: max(trunc(value), 0)
  defp normalize_non_neg_count(_value), do: 0

  defp spawn_resource_processes(spawn_count) when spawn_count <= 0, do: []

  defp spawn_resource_processes(spawn_count) do
    for _ <- 1..spawn_count do
      spawn(&wait_for_stop_message/0)
    end
  end

  defp wait_for_stop_message do
    receive do
      :stop -> :ok
    after
      60_000 -> :ok
    end
  end

  defp build_process_cleanup_fn(spawned) do
    fn ->
      Enum.each(spawned, &stop_if_alive/1)
      :ok
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end
end
