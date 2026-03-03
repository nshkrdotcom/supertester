defmodule Supertester.Internal.ProcessLifecycleTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.ProcessLifecycle

  test "stop_process_safely/2 gracefully stops regular processes" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    assert :ok = ProcessLifecycle.stop_process_safely(pid, 200)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 50
  end

  test "stop_process_safely/2 accepts process info maps" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    assert :ok = ProcessLifecycle.stop_process_safely(%{pid: pid}, 200)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 50
  end

  test "stop_process_safely/2 escalates to kill when shutdown is trapped" do
    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(parent, :trap_exit_ready)

        receive do
          {:EXIT, _from, :shutdown} ->
            # Keep running to force escalation.
            receive do
              :halt -> :ok
            end
        end
      end)

    assert_receive :trap_exit_ready

    ref = Process.monitor(pid)
    assert :ok = ProcessLifecycle.stop_process_safely(pid, 20)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 100
  end
end
