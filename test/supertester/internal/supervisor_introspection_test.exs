defmodule Supertester.Internal.SupervisorIntrospectionTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.SupervisorIntrospection

  defmodule Worker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  defmodule OneForOneSupervisor do
    use Supervisor

    def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok) do
      children = [%{id: :w1, start: {Worker, :start_link, [[]]}}]
      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule OneForAllSupervisor do
    use Supervisor

    def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok) do
      children = [%{id: :w1, start: {Worker, :start_link, [[]]}}]
      Supervisor.init(children, strategy: :one_for_all)
    end
  end

  describe "extract_supervisor_strategy/1" do
    test "extracts :one_for_one from standard Supervisor" do
      {:ok, sup} = OneForOneSupervisor.start_link()
      assert SupervisorIntrospection.extract_supervisor_strategy(sup) == :one_for_one
    end

    test "extracts :one_for_all from standard Supervisor" do
      {:ok, sup} = OneForAllSupervisor.start_link()
      assert SupervisorIntrospection.extract_supervisor_strategy(sup) == :one_for_all
    end

    test "extracts strategy from DynamicSupervisor (map-based state)" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      assert SupervisorIntrospection.extract_supervisor_strategy(sup) == :one_for_one
    end

    test "returns nil for dead process" do
      {:ok, sup} = OneForOneSupervisor.start_link()
      Supervisor.stop(sup)
      assert SupervisorIntrospection.extract_supervisor_strategy(sup) == nil
    end
  end

  describe "resolve_supervisor_pid/1" do
    test "returns pid when given a pid" do
      {:ok, sup} = OneForOneSupervisor.start_link()
      assert SupervisorIntrospection.resolve_supervisor_pid(sup) == sup
    end

    test "resolves pid from registered atom name" do
      name = :"introspection_test_sup_#{System.unique_integer([:positive])}"
      {:ok, sup} = OneForOneSupervisor.start_link(name: name)
      assert SupervisorIntrospection.resolve_supervisor_pid(name) == sup
    end

    test "resolves pid from {:global, _} tuple" do
      global_name = {:introspection_test, self(), System.unique_integer([:positive])}
      {:ok, sup} = OneForOneSupervisor.start_link(name: {:global, global_name})
      assert SupervisorIntrospection.resolve_supervisor_pid({:global, global_name}) == sup
    end

    test "returns nil for unregistered atom name" do
      assert SupervisorIntrospection.resolve_supervisor_pid(:definitely_not_registered) == nil
    end

    test "returns nil for unrecognized input" do
      assert SupervisorIntrospection.resolve_supervisor_pid("not_a_valid_ref") == nil
      assert SupervisorIntrospection.resolve_supervisor_pid(42) == nil
    end
  end

  describe "group_child_pids_by_id/1" do
    test "groups pids by child id" do
      {:ok, sup} = OneForOneSupervisor.start_link()
      children = Supervisor.which_children(sup)
      grouped = SupervisorIntrospection.group_child_pids_by_id(children)

      assert Map.has_key?(grouped, :w1)
      assert [pid] = grouped[:w1]
      assert is_pid(pid)
    end

    test "skips children with :undefined pid" do
      children = [{:w1, :undefined, :worker, [Worker]}]
      assert SupervisorIntrospection.group_child_pids_by_id(children) == %{}
    end

    test "returns empty map for empty list" do
      assert SupervisorIntrospection.group_child_pids_by_id([]) == %{}
    end

    test "groups multiple children under same id" do
      pid1 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      pid2 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      children = [
        {:w1, pid1, :worker, [Worker]},
        {:w1, pid2, :worker, [Worker]},
        {:w2, spawn(fn -> :ok end), :worker, [Worker]}
      ]

      grouped = SupervisorIntrospection.group_child_pids_by_id(children)
      assert length(grouped[:w1]) == 2
      assert Map.has_key?(grouped, :w2)

      send(pid1, :stop)
      send(pid2, :stop)
    end
  end
end
