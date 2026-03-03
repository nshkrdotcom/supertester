defmodule Supertester.Internal.SupervisorIntrospection do
  @moduledoc false
  # Internal module consolidating supervisor introspection utilities
  # used by Assertions, SupervisorHelpers, and ChaosHelpers.
  alias Supertester.Internal.ProcessRef

  @strategies [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

  @doc false
  @spec extract_supervisor_strategy(Supervisor.supervisor()) :: atom() | nil
  def extract_supervisor_strategy(supervisor) do
    supervisor
    |> fetch_supervisor_state()
    |> do_extract_strategy()
  end

  @doc false
  @spec extract_supervisor_module(Supervisor.supervisor()) :: module() | nil
  def extract_supervisor_module(supervisor) do
    supervisor
    |> fetch_supervisor_state()
    |> do_extract_supervisor_module()
  end

  @doc false
  @spec resolve_supervisor_pid(term()) :: pid() | nil
  def resolve_supervisor_pid(ref), do: ProcessRef.resolve(ref)

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

  @doc false
  @spec safe_children(Supervisor.supervisor()) :: [{term(), pid() | atom(), atom(), [module()]}]
  def safe_children(supervisor) do
    Supervisor.which_children(supervisor)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc false
  @spec replacement_count([pid()], [pid()]) :: non_neg_integer()
  def replacement_count(_initial_pids, []), do: 0

  def replacement_count(initial_pids, current_pids) do
    initial_set = MapSet.new(initial_pids)
    current_set = MapSet.new(current_pids)
    survivor_count = MapSet.intersection(initial_set, current_set) |> MapSet.size()
    replacement_count = max(MapSet.size(current_set) - survivor_count, 0)

    min(length(initial_pids), replacement_count)
  end

  @doc false
  @spec child_restarted?([pid()], [pid()]) :: boolean()
  def child_restarted?(_initial_pids, []), do: false

  def child_restarted?(initial_pids, current_pids) do
    replacement_count(initial_pids, current_pids) > 0
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

  defp do_extract_supervisor_module(%{mod: module}) when is_atom(module), do: module

  defp do_extract_supervisor_module({:state, {_pid, module}, _strategy, _rest})
       when is_atom(module),
       do: module

  defp do_extract_supervisor_module(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.find_value(&module_from_term/1)
  end

  defp do_extract_supervisor_module(_), do: nil

  defp module_from_term({pid, module}) when is_pid(pid) and is_atom(module), do: module
  defp module_from_term(_), do: nil

  defp fetch_supervisor_state(supervisor) do
    :sys.get_state(supervisor)
  catch
    :exit, _ -> nil
  end
end
