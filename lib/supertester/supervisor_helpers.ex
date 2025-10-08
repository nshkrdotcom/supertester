defmodule Supertester.SupervisorHelpers do
  @moduledoc """
  Specialized testing utilities for supervision trees.

  This module provides helpers for testing supervisor behavior, restart strategies,
  and supervision tree structures.

  ## Key Features

  - Test restart strategies (one_for_one, one_for_all, rest_for_one)
  - Trace supervision events
  - Verify supervision tree structure
  - Wait for supervisor stabilization

  ## Usage

      import Supertester.SupervisorHelpers

      test "supervisor restart strategy" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

        result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})

        assert result.restarted == [:worker_1]
        assert result.not_restarted == [:worker_2, :worker_3]
      end
  """

  @type restart_scenario ::
          {:kill_child, child_id :: term()}
          | {:kill_children, [child_id :: term()]}
          | {:cascade_failure, start_child_id :: term()}

  @type test_result :: %{
          restarted: [term()],
          not_restarted: [term()],
          supervisor_alive: boolean()
        }

  @type tree_structure :: %{
          supervisor: module(),
          strategy: atom(),
          children: [child_structure()]
        }

  @type child_structure ::
          {child_id :: term(), module :: module()}
          | {child_id :: term(), tree_structure()}

  @type supervision_event ::
          {:child_started, child_id :: term(), pid()}
          | {:child_terminated, child_id :: term(), pid(), reason :: term()}
          | {:child_restarted, child_id :: term(), old_pid :: pid(), new_pid :: pid()}

  @doc """
  Tests supervisor restart strategies with various failure scenarios.

  ## Parameters

  - `supervisor` - The supervisor PID or name
  - `strategy` - Expected strategy (:one_for_one, :one_for_all, :rest_for_one)
  - `scenario` - The failure scenario to test

  ## Examples

      test "one_for_one restarts only failed child" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

        result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})

        assert result.restarted == [:worker_1]
        assert result.not_restarted == [:worker_2, :worker_3]
      end
  """
  @spec test_restart_strategy(Supervisor.supervisor(), atom(), restart_scenario()) ::
          test_result()
  def test_restart_strategy(supervisor, _strategy, scenario) do
    # Get initial state
    initial_children = Supervisor.which_children(supervisor)

    initial_state =
      Map.new(initial_children, fn {id, pid, _type, _mods} ->
        {id, pid}
      end)

    # Execute scenario
    case scenario do
      {:kill_child, child_id} ->
        kill_child(supervisor, child_id)

      {:kill_children, child_ids} ->
        Enum.each(child_ids, fn child_id ->
          kill_child(supervisor, child_id)
        end)

      {:cascade_failure, start_child_id} ->
        # TODO: Implement cascade failure simulation
        kill_child(supervisor, start_child_id)
    end

    # Wait for supervisor to stabilize
    wait_for_supervisor_stabilization(supervisor)

    # Get new state
    new_children = Supervisor.which_children(supervisor)

    new_state =
      Map.new(new_children, fn {id, pid, _type, _mods} ->
        {id, pid}
      end)

    # Compare states
    restarted =
      Enum.filter(Map.keys(initial_state), fn id ->
        initial_state[id] != new_state[id]
      end)

    not_restarted =
      Enum.filter(Map.keys(initial_state), fn id ->
        initial_state[id] == new_state[id]
      end)

    %{
      restarted: restarted,
      not_restarted: not_restarted,
      supervisor_alive: Process.alive?(supervisor)
    }
  end

  @doc """
  Traces all supervision events for verification.

  ## Parameters

  - `supervisor` - The supervisor PID to trace
  - `opts` - Options (currently unused)

  ## Returns

  `{:ok, stop_fn}` where stop_fn returns the list of traced events

  ## Examples

      test "supervisor restart behavior" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)
        {:ok, stop_trace} = trace_supervision_events(supervisor)

        # Cause some failures
        children = Supervisor.which_children(supervisor)
        Enum.each(children, fn {_id, pid, _type, _mods} ->
          Process.exit(pid, :kill)
        end)

        # Get events
        events = stop_trace.()

        # Verify restart sequence
        assert length(events) >= 6  # 3 terminates + 3 restarts
      end
  """
  @spec trace_supervision_events(Supervisor.supervisor(), keyword()) ::
          {:ok, (-> [supervision_event()])}
  def trace_supervision_events(supervisor, _opts \\ []) do
    # Simplified implementation - collect events by monitoring the supervisor
    # In a real implementation, this would hook into supervisor internals

    initial_children = Supervisor.which_children(supervisor)

    stop_fn = fn ->
      current_children = Supervisor.which_children(supervisor)

      # Detect restarts by comparing PIDs
      events =
        Enum.flat_map(initial_children, fn {id, initial_pid, _type, _mods} ->
          case Enum.find(current_children, fn {cid, _cpid, _ctype, _cmods} -> cid == id end) do
            {_id, ^initial_pid, _type, _mods} ->
              # Same PID, no restart
              []

            {_id, new_pid, _type, _mods} when is_pid(new_pid) ->
              # Different PID, restart occurred
              [
                {:child_terminated, id, initial_pid, :kill},
                {:child_restarted, id, initial_pid, new_pid}
              ]

            _ ->
              # Child removed
              [{:child_terminated, id, initial_pid, :removed}]
          end
        end)

      # Detect new children
      new_starts =
        Enum.flat_map(current_children, fn {id, pid, _type, _mods} ->
          if Enum.any?(initial_children, fn {initial_id, _ipid, _itype, _imods} ->
               initial_id == id
             end) do
            []
          else
            [{:child_started, id, pid}]
          end
        end)

      events ++ new_starts
    end

    {:ok, stop_fn}
  end

  @doc """
  Asserts supervision tree matches expected structure.

  ## Parameters

  - `supervisor` - The supervisor PID
  - `expected` - Expected tree structure

  ## Examples

      test "supervision tree structure" do
        {:ok, root} = setup_isolated_supervisor(RootSupervisor)

        assert_supervision_tree_structure(root, %{
          supervisor: RootSupervisor,
          strategy: :one_for_one,
          children: [
            {:cache, CacheServer},
            {:workers, %{
              supervisor: WorkerSupervisor,
              strategy: :one_for_all,
              children: [
                {:worker_1, Worker},
                {:worker_2, Worker}
              ]
            }}
          ]
        })
      end
  """
  @spec assert_supervision_tree_structure(Supervisor.supervisor(), tree_structure()) :: :ok
  def assert_supervision_tree_structure(supervisor, expected) do
    children = Supervisor.which_children(supervisor)

    # Check child count
    expected_children = Map.get(expected, :children, [])

    if length(children) != length(expected_children) do
      raise """
      Expected supervisor to have #{length(expected_children)} children, got #{length(children)}

      Expected: #{inspect(expected_children)}
      Got: #{inspect(children)}
      """
    end

    # Check each child
    Enum.each(expected_children, fn expected_child ->
      case expected_child do
        {child_id, nested_structure} when is_map(nested_structure) ->
          # Nested supervisor - recurse
          child = Enum.find(children, fn {id, _pid, _type, _mods} -> id == child_id end)

          if child == nil do
            raise "Expected child supervisor #{inspect(child_id)} not found"
          end

          {_id, child_pid, _type, _mods} = child
          assert_supervision_tree_structure(child_pid, nested_structure)

        {child_id, _module} ->
          # Simple child - verify it exists
          unless Enum.any?(children, fn {id, _pid, _type, _mods} -> id == child_id end) do
            raise "Expected child #{inspect(child_id)} not found in supervisor"
          end
      end
    end)

    :ok
  end

  @doc """
  Waits until supervisor has all children running and stable.

  ## Parameters

  - `supervisor` - The supervisor PID
  - `timeout` - Timeout in milliseconds (default: 5000)

  ## Examples

      test "supervisor recovery" do
        {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

        # Cause chaos
        children = Supervisor.which_children(supervisor)
        Enum.each(children, fn {_id, pid, _type, _mods} ->
          Process.exit(pid, :kill)
        end)

        # Wait for stabilization
        assert :ok = wait_for_supervisor_stabilization(supervisor)

        # All should be alive
        assert_all_children_alive(supervisor)
      end
  """
  @spec wait_for_supervisor_stabilization(Supervisor.supervisor(), timeout()) ::
          :ok | {:error, :timeout}
  def wait_for_supervisor_stabilization(supervisor, timeout \\ 5000) do
    case Supertester.UnifiedTestFoundation.wait_for_supervision_tree_ready(supervisor, timeout) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets the count of active children in a supervisor.

  ## Parameters

  - `supervisor` - The supervisor PID

  ## Returns

  Number of active children

  ## Examples

      count = get_active_child_count(supervisor)
      assert count == 3
  """
  @spec get_active_child_count(Supervisor.supervisor()) :: non_neg_integer()
  def get_active_child_count(supervisor) do
    %{active: active} = Supervisor.count_children(supervisor)
    active
  end

  @doc """
  Gets the restart strategy of a supervisor.

  Note: This is a best-effort function as Elixir doesn't provide direct access
  to the strategy. Returns `:unknown` if strategy cannot be determined.

  ## Parameters

  - `supervisor` - The supervisor PID

  ## Returns

  Strategy atom or `:unknown`
  """
  @spec get_supervisor_strategy(Supervisor.supervisor()) :: atom()
  def get_supervisor_strategy(_supervisor) do
    # Elixir doesn't expose supervisor strategy directly
    # This would require inspecting internal state which is not reliable
    :unknown
  end

  # Private functions

  defp kill_child(supervisor, child_id) do
    children = Supervisor.which_children(supervisor)

    case Enum.find(children, fn {id, _pid, _type, _mods} -> id == child_id end) do
      {_id, pid, _type, _mods} when is_pid(pid) ->
        Process.exit(pid, :kill)
        :ok

      _ ->
        {:error, :child_not_found}
    end
  end

  # Note: event_collector is currently unused but kept for future real-time event tracing
  # defp event_collector(events) do
  #   receive do
  #     {:get_events, from} ->
  #       send(from, {:events, Enum.reverse(events)})
  #
  #     event ->
  #       event_collector([event | events])
  #   after
  #     10000 ->
  #       # Timeout after 10 seconds of inactivity
  #       event_collector(events)
  #   end
  # end
end
