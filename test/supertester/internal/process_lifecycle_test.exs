defmodule Supertester.Internal.ProcessLifecycleTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.ProcessLifecycle

  defmodule LifecycleGenServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, :ok}
  end

  defmodule LifecycleSupervisor do
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok) do
      children = [
        %{
          id: :worker,
          start: {LifecycleGenServer, :start_link, [[]]}
        }
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

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

  test "stop_genserver_safely/2 stops live GenServer pids" do
    {:ok, pid} = LifecycleGenServer.start_link([])
    ref = Process.monitor(pid)

    assert :ok = ProcessLifecycle.stop_genserver_safely(pid, 200)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
  end

  test "stop_supervisor_safely/2 stops supervisor and worker children" do
    {:ok, supervisor} = LifecycleSupervisor.start_link([])
    [{:worker, worker, :worker, _}] = Supervisor.which_children(supervisor)

    supervisor_ref = Process.monitor(supervisor)
    worker_ref = Process.monitor(worker)

    assert :ok = ProcessLifecycle.stop_supervisor_safely(supervisor, 300)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 300
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :normal}, 300
  end
end
