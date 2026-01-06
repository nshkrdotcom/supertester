defmodule EchoLab.SupervisorHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.{Assertions, OTPHelpers, SupervisorHelpers}

  alias EchoLab.{OneForAllSupervisor, OneForOneSupervisor, RootSupervisor}

  test "test_restart_strategy one_for_one" do
    prefix = "sup_one_for_one_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        OneForOneSupervisor,
        "sup_one",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)

    result = test_restart_strategy(sup, :one_for_one, {:kill_child, :worker_a})

    assert :worker_a in result.restarted
    assert :worker_b in result.not_restarted
    assert result.supervisor_alive
  end

  test "test_restart_strategy one_for_all" do
    prefix = "sup_one_for_all_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        OneForAllSupervisor,
        "sup_all",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)

    result = test_restart_strategy(sup, :one_for_all, {:kill_child, :alpha})

    assert :alpha in result.restarted
    assert :beta in result.restarted
  end

  test "trace_supervision_events captures restart events" do
    prefix = "trace_sup_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        OneForOneSupervisor,
        "trace",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)
    {:ok, stop_trace} = trace_supervision_events(sup)

    child_pid =
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {:worker_b, pid, _type, _mods} -> pid
        _ -> nil
      end)

    Process.exit(child_pid, :kill)
    :ok = wait_for_supervisor_stabilization(sup)

    events = stop_trace.()
    assert Enum.any?(events, &match?({:child_restarted, :worker_b, _, _}, &1))
  end

  test "assert_supervision_tree_structure and child counts" do
    prefix = "root_sup_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        RootSupervisor,
        "root",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)

    assert_supervision_tree_structure(sup, %{
      supervisor: RootSupervisor,
      strategy: :one_for_one,
      children: [
        {:worker_supervisor,
         %{
           supervisor: OneForOneSupervisor,
           strategy: :one_for_one,
           children: [
             {:worker_a, EchoLab.Worker},
             {:worker_b, EchoLab.Worker},
             {:restart_worker, EchoLab.Worker}
           ]
         }},
        {:counter, EchoLab.Counter}
      ]
    })

    assert get_active_child_count(sup) == 2
    assert_all_children_alive(sup)
  end
end
