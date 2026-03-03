defmodule Supertester.Internal.SharedRegistry do
  @moduledoc false

  @registry_name :supertester_shared_registry

  @spec name() :: atom()
  def name, do: @registry_name

  @spec ensure_started() :: {:ok, pid()}
  def ensure_started do
    case Process.whereis(@registry_name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case Registry.start_link(keys: :unique, name: @registry_name) do
          {:ok, pid} ->
            Process.unlink(pid)
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}
        end
    end
  end
end
