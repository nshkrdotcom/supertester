defmodule Supertester.Internal.ProcessWatchTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.ProcessWatch

  test "await_down/3 returns down reason when process exits" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    assert {:down, :killed} = ProcessWatch.await_down(ref, pid, 100)
  end

  test "await_down/3 times out and flushes monitor messages" do
    pid =
      spawn(fn ->
        receive do
        after
          50 -> :ok
        end
      end)

    ref = Process.monitor(pid)
    assert :timeout = ProcessWatch.await_down(ref, pid, 5)

    Process.exit(pid, :kill)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
  end
end
