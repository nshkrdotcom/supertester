defmodule Supertester.AssertionsTest do
  use ExUnit.Case, async: true

  import Supertester.Assertions

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
      children = [
        %{id: :worker_1, start: {Worker, :start_link, [[]]}}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  test "assert_supervisor_strategy raises for strategy mismatch" do
    {:ok, supervisor} = OneForOneSupervisor.start_link()

    assert_raise RuntimeError, ~r/Expected supervisor strategy/, fn ->
      assert_supervisor_strategy(supervisor, :one_for_all)
    end
  end

  test "assert_no_process_leaks detects leaked OTP processes" do
    try do
      assert_raise RuntimeError, ~r/Process leaks detected/, fn ->
        assert_no_process_leaks(fn ->
          {:ok, pid} = Agent.start_link(fn -> :ready end)
          send(self(), {:leaked_pid, pid})
        end)
      end
    after
      receive do
        {:leaked_pid, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            Agent.stop(pid)
          end
      after
        0 ->
          :ok
      end
    end
  end

  test "assert_no_process_leaks ignores unrelated concurrent processes" do
    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:schedule_spawn, delay_ms} ->
            Process.send_after(self(), :spawn_unrelated, delay_ms)

            receive do
              :spawn_unrelated ->
                unrelated =
                  spawn(fn ->
                    receive do
                      :stop -> :ok
                    after
                      1000 -> :ok
                    end
                  end)

                send(parent, {:unrelated_started, unrelated})

                receive do
                  :stop -> send(unrelated, :stop)
                after
                  1500 -> :ok
                end
            end
        end
      end)

    send(controller, {:schedule_spawn, 5})

    try do
      assert :ok =
               assert_no_process_leaks(fn ->
                 receive do
                 after
                   40 -> :ok
                 end
               end)
    after
      send(controller, :stop)

      receive do
        {:unrelated_started, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            send(pid, :stop)
          end
      after
        100 ->
          :ok
      end
    end
  end

  test "assert_no_process_leaks detects leaked descendant processes" do
    parent = self()

    try do
      assert_raise RuntimeError, ~r/Process leaks detected/, fn ->
        assert_no_process_leaks(fn ->
          spawn(fn ->
            leaked =
              spawn(fn ->
                receive do
                  :stop -> :ok
                after
                  5_000 -> :ok
                end
              end)

            send(parent, {:leaked_descendant, leaked})
          end)

          receive do
            {:leaked_descendant, _pid} -> :ok
          after
            100 -> :ok
          end
        end)
      end
    after
      receive do
        {:leaked_descendant, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            send(pid, :stop)
          end
      after
        0 -> :ok
      end
    end
  end

  test "assert_no_process_leaks detects delayed descendant leaks" do
    parent = self()

    try do
      assert_raise RuntimeError, ~r/Process leaks detected/, fn ->
        assert_no_process_leaks(fn ->
          spawn(fn ->
            Process.send_after(self(), :spawn_delayed_leak, 40)

            receive do
              :spawn_delayed_leak ->
                leaked =
                  spawn(fn ->
                    receive do
                      :stop -> :ok
                    after
                      5_000 -> :ok
                    end
                  end)

                send(parent, {:delayed_leak, leaked})
            after
              100 -> :ok
            end
          end)
        end)
      end
    after
      receive do
        {:delayed_leak, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            send(pid, :stop)
          end
      after
        0 -> :ok
      end
    end
  end

  test "assert_supervisor_strategy succeeds when strategy matches" do
    {:ok, supervisor} = OneForOneSupervisor.start_link()
    assert :ok = assert_supervisor_strategy(supervisor, :one_for_one)
  end

  test "assert_supervisor_strategy works with DynamicSupervisor (map-based state)" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert :ok = assert_supervisor_strategy(supervisor, :one_for_one)
  end

  test "assert_no_process_leaks propagates exceptions from the operation" do
    assert_raise RuntimeError, "boom", fn ->
      assert_no_process_leaks(fn ->
        raise "boom"
      end)
    end
  end

  test "assert_no_process_leaks ignores short-lived transient spawned processes" do
    assert :ok =
             assert_no_process_leaks(fn ->
               spawn(fn ->
                 receive do
                 after
                   35 -> :ok
                 end
               end)
             end)
  end
end
