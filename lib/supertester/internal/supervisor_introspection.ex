defmodule Supertester.Internal.SupervisorIntrospection do
  @moduledoc false
  # Internal module consolidating supervisor introspection utilities
  # used by Assertions, SupervisorHelpers, and ChaosHelpers.

  @strategies [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

  @doc false
  @spec extract_supervisor_strategy(Supervisor.supervisor()) :: atom() | nil
  def extract_supervisor_strategy(supervisor) do
    supervisor
    |> fetch_supervisor_state()
    |> do_extract_strategy()
  end

  @doc false
  @spec resolve_supervisor_pid(term()) :: pid() | nil
  def resolve_supervisor_pid(pid) when is_pid(pid), do: pid
  def resolve_supervisor_pid(name) when is_atom(name), do: Process.whereis(name)

  def resolve_supervisor_pid({:global, name}) do
    case :global.whereis_name(name) do
      :undefined -> nil
      pid -> pid
    end
  end

  def resolve_supervisor_pid({:via, module, name}) do
    case module.whereis_name(name) do
      :undefined -> nil
      pid -> pid
    end
  end

  def resolve_supervisor_pid(_), do: nil

  @doc false
  @spec group_child_pids_by_id([{term(), pid() | atom(), atom(), [module()]}]) ::
          %{term() => [pid()]}
  def group_child_pids_by_id(children) do
    Enum.reduce(children, %{}, fn
      {id, pid, _type, _mods}, acc when is_pid(pid) ->
        Map.update(acc, id, [pid], &[pid | &1])

      _child, acc ->
        acc
    end)
  end

  # Strategy extraction — handles maps (DynamicSupervisor), specific tuples,
  # and generic tuples (scanning for known strategy atoms).
  defp do_extract_strategy(%{strategy: strategy}) when strategy in @strategies,
    do: strategy

  defp do_extract_strategy({:state, _name, strategy, _rest})
       when strategy in @strategies,
       do: strategy

  defp do_extract_strategy(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.find(fn value -> value in @strategies end)
  end

  defp do_extract_strategy(_), do: nil

  defp fetch_supervisor_state(supervisor) do
    :sys.get_state(supervisor)
  catch
    :exit, _ -> nil
  end
end
