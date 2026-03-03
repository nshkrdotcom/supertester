defmodule Supertester.Internal.ProcessRef do
  @moduledoc false

  @spec resolve(term()) :: pid() | nil
  def resolve(pid) when is_pid(pid), do: pid
  def resolve(name) when is_atom(name), do: Process.whereis(name)

  def resolve({:global, name}) do
    case :global.whereis_name(name) do
      :undefined -> nil
      pid when is_pid(pid) -> pid
    end
  end

  def resolve({:via, module, name}) do
    case module.whereis_name(name) do
      :undefined -> nil
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  def resolve(_), do: nil

  @spec alive?(term()) :: boolean()
  def alive?(ref) do
    case resolve(ref) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
