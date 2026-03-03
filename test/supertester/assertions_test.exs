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
end
