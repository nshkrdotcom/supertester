defmodule Supertester.SupervisorHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.SupervisorHelpers

  defmodule Worker do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts) do
      id = Keyword.get(opts, :id, :worker)
      GenServer.start_link(__MODULE__, id, opts)
    end

    @impl true
    def init(id) do
      {:ok, %{id: id, count: 0}}
    end

    @impl true
    def handle_call(:crash, _from, _state) do
      raise "intentional crash"
    end

    def handle_call(:get_id, _from, state) do
      {:reply, state.id, state}
    end
  end

  defmodule TestSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    @impl true
    def init(opts) do
      strategy = Keyword.get(opts, :strategy, :one_for_one)
      children_count = Keyword.get(opts, :children, 3)

      children =
        for i <- 1..children_count do
          %{
            id: :"worker_#{i}",
            start:
              {Worker, :start_link,
               [[id: i, name: :"worker_#{i}_#{:erlang.unique_integer([:positive])}"]]}
          }
        end

      Supervisor.init(children, strategy: strategy)
    end
  end

  describe "test_restart_strategy/3" do
    test "one_for_one restarts only the killed child" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 3)

      # Get initial children
      initial_children = Supervisor.which_children(supervisor)
      assert length(initial_children) == 3

      # Get PIDs before killing
      initial_pids = Enum.map(initial_children, fn {_id, pid, _type, _mods} -> pid end)

      # Kill the first worker
      [first_worker_pid | other_pids] = initial_pids
      Process.exit(first_worker_pid, :kill)

      # Wait for supervisor to restart
      :timer.sleep(50)

      # Get new children
      new_children = Supervisor.which_children(supervisor)
      new_pids = Enum.map(new_children, fn {_id, pid, _type, _mods} -> pid end)

      # First worker should have a new PID
      refute first_worker_pid in new_pids

      # Other workers should have the same PIDs
      assert Enum.all?(other_pids, fn pid -> pid in new_pids end)
    end

    test "one_for_all restarts all children when one dies" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_all, children: 3)

      # Get initial PIDs
      initial_children = Supervisor.which_children(supervisor)
      initial_pids = Enum.map(initial_children, fn {_id, pid, _type, _mods} -> pid end)

      # Kill one worker
      first_pid = hd(initial_pids)
      Process.exit(first_pid, :kill)

      # Wait for supervisor to restart all
      :timer.sleep(50)

      # Get new PIDs
      new_children = Supervisor.which_children(supervisor)
      new_pids = Enum.map(new_children, fn {_id, pid, _type, _mods} -> pid end)

      # All PIDs should be different
      refute Enum.any?(initial_pids, fn pid -> pid in new_pids end)
    end
  end

  describe "trace_supervision_events/2" do
    test "traces child start events" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 2)

      {:ok, stop_trace} = trace_supervision_events(supervisor)

      # Start more children by restarting
      [{_id, pid, _type, _mods} | _] = Supervisor.which_children(supervisor)
      Process.exit(pid, :kill)
      :timer.sleep(50)

      # Stop tracing
      events = stop_trace.()

      # Should have restart events (which include starts)
      restart_events = Enum.filter(events, &match?({:child_restarted, _, _, _}, &1))
      assert length(restart_events) >= 1
    end

    test "traces child termination and restart events" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 1)

      {:ok, stop_trace} = trace_supervision_events(supervisor)

      # Kill the child
      [{_id, pid, _type, _mods}] = Supervisor.which_children(supervisor)
      Process.exit(pid, :kill)

      # Wait for restart
      :timer.sleep(50)

      events = stop_trace.()

      # Should have termination event
      term_events = Enum.filter(events, &match?({:child_terminated, _, _, _}, &1))
      assert length(term_events) >= 1

      # Should have restart event
      restart_events = Enum.filter(events, &match?({:child_restarted, _, _, _}, &1))
      assert length(restart_events) >= 1
    end
  end

  describe "assert_supervision_tree_structure/2" do
    test "verifies supervisor has expected children" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 3)

      assert_supervision_tree_structure(supervisor, %{
        supervisor: TestSupervisor,
        strategy: :one_for_one,
        children: [
          {:worker_1, Worker},
          {:worker_2, Worker},
          {:worker_3, Worker}
        ]
      })
    end

    test "raises when child count doesn't match" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 2)

      assert_raise RuntimeError, fn ->
        assert_supervision_tree_structure(supervisor, %{
          supervisor: TestSupervisor,
          strategy: :one_for_one,
          children: [
            {:worker_1, Worker},
            {:worker_2, Worker},
            # This doesn't exist
            {:worker_3, Worker}
          ]
        })
      end
    end
  end

  describe "wait_for_supervisor_stabilization/2" do
    test "waits until supervisor has all children running" do
      {:ok, supervisor} = TestSupervisor.start_link(strategy: :one_for_one, children: 3)

      # Kill a child
      [{_id, pid, _type, _mods} | _rest] = Supervisor.which_children(supervisor)
      Process.exit(pid, :kill)

      # Wait for stabilization
      assert :ok = wait_for_supervisor_stabilization(supervisor)

      # All children should be alive
      children = Supervisor.which_children(supervisor)
      assert length(children) == 3

      assert Enum.all?(children, fn {_id, pid, _type, _mods} ->
               is_pid(pid) and Process.alive?(pid)
             end)
    end
  end
end
