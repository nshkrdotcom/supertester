defmodule EchoLab.AssertionsTest do
  use ExUnit.Case, async: false

  import Supertester.Assertions

  alias EchoLab.{OneForOneSupervisor, TestableCounter}

  test "process and genserver assertions" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert_process_alive(pid)

    send(pid, :stop)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert_process_dead(pid)

    {:ok, counter} = TestableCounter.start_link(initial: 2)
    assert_genserver_state(counter, %{count: 2})
    assert_genserver_state(counter, fn state -> state.count == 2 end)
    assert_genserver_responsive(counter)
    assert_genserver_handles_message(counter, {:add, 3}, 5)

    {:ok, agent} = Agent.start_link(fn -> :ready end)
    assert_genserver_state(agent, :ready)
    Agent.stop(agent)
  end

  test "process restart and supervisor assertions" do
    prefix = "assertions_#{System.unique_integer([:positive])}"
    sup_name = EchoLab.Names.child_name(prefix, :supervisor)
    sup = start_supervised!({OneForOneSupervisor, name_prefix: prefix, name: sup_name})

    restart_name = EchoLab.Names.child_name(prefix, :restart_worker)
    original_pid = Process.whereis(restart_name)

    Process.exit(original_pid, :kill)
    assert {:ok, _} = Supertester.OTPHelpers.wait_for_process_restart(restart_name, original_pid)
    assert_process_restarted(restart_name, original_pid)

    assert_supervisor_strategy(sup, :one_for_one)
    assert_child_count(sup, 3)
    assert_all_children_alive(sup)
  end

  test "performance and leak assertions" do
    assert_memory_usage_stable(fn -> Enum.sum(1..10) end, 0.5)

    assert_no_process_leaks(fn ->
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end)

    measurement = %{max_time: 5, max_memory: 50, max_reductions: 1}
    assert_performance_within_bounds(measurement, %{max_time: 10, max_memory: 100})
  end
end
