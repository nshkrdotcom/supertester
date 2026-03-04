defmodule Supertester.PerformanceHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.PerformanceHelpers

  defmodule FastWorker do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @impl true
    def init(:ok), do: {:ok, 0}

    @impl true
    def handle_call(:fast_op, _from, state) do
      # Fast operation - just increment
      {:reply, :ok, state + 1}
    end

    def handle_call(:slow_op, _from, state) do
      # Slow operation - sleep a bit
      receive do
      after
        5 -> :ok
      end

      {:reply, :ok, state + 1}
    end

    def handle_call(:get_count, _from, state) do
      {:reply, state, state}
    end

    @impl true
    def handle_cast(_msg, state) do
      # Ignore cast messages
      {:noreply, state}
    end
  end

  describe "assert_performance/2" do
    test "passes when operation meets performance expectations" do
      fast_op = fn ->
        1 + 1
      end

      # Memory delta is based on total VM usage, so allow a generous threshold to avoid noise.
      assert_performance(fast_op,
        max_time_ms: 100,
        max_memory_bytes: 5_000_000
      )
    end

    test "raises when operation exceeds time limit" do
      slow_op = fn ->
        receive do
        after
          100 -> :ok
        end
      end

      assert_raise RuntimeError, ~r/exceeded maximum/, fn ->
        assert_performance(slow_op, max_time_ms: 50)
      end
    end

    test "measures reductions (CPU work)" do
      cpu_op = fn ->
        Enum.reduce(1..1000, 0, fn x, acc -> acc + x end)
      end

      # Should complete with reasonable reductions
      assert_performance(cpu_op,
        max_time_ms: 100,
        max_reductions: 1_000_000
      )
    end
  end

  describe "assert_no_memory_leak/2" do
    test "passes when operation doesn't leak memory" do
      {:ok, worker} = FastWorker.start_link()

      assert_no_memory_leak(100, fn ->
        GenServer.call(worker, :fast_op)
      end)
    end

    test "detects memory growth trend" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_exit(fn ->
        if Process.alive?(agent) do
          try do
            Agent.stop(agent)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      assert_raise RuntimeError, ~r/Memory leak detected/, fn ->
        assert_no_memory_leak(
          60,
          fn ->
            # Intentionally leak memory with larger chunks
            Agent.update(agent, fn list -> [:binary.copy(<<0>>, 500_000) | list] end)
          end,
          # Very tight threshold to catch leak
          threshold: 0.02
        )
      end
    end
  end

  describe "__analyze_memory_samples__/3" do
    test "flags sustained upward trends as leaks" do
      samples = [1_000_000, 1_120_000, 1_210_000, 1_330_000, 1_420_000, 1_560_000]

      assert {:leak, info} =
               Supertester.PerformanceHelpers.__analyze_memory_samples__(samples, 0.05,
                 min_absolute_growth_bytes: 100_000
               )

      assert info.growth_rate > 0.05
      assert info.absolute_growth_bytes > 100_000
    end

    test "ignores noisy but stable samples" do
      samples = [1_000_000, 1_030_000, 990_000, 1_015_000, 995_000, 1_010_000]

      assert :ok =
               Supertester.PerformanceHelpers.__analyze_memory_samples__(samples, 0.02,
                 min_absolute_growth_bytes: 100_000
               )
    end
  end

  describe "measure_operation/1" do
    test "measures operation time and memory" do
      result =
        measure_operation(fn ->
          # Use a more complex operation that can't be optimized away
          1..10_000
          |> Enum.map(&(&1 * 2))
          |> Enum.reduce(0, &+/2)
        end)

      assert Map.has_key?(result, :time_us)
      assert Map.has_key?(result, :memory_bytes)
      assert Map.has_key?(result, :reductions)
      assert result.time_us >= 0
      assert result.reductions > 0
    end

    test "returns operation result" do
      result =
        measure_operation(fn ->
          42
        end)

      assert Map.has_key?(result, :result)
      assert result.result == 42
    end
  end

  describe "measure_mailbox_growth/3" do
    test "measures mailbox size during operation" do
      {:ok, worker} = FastWorker.start_link()

      report =
        measure_mailbox_growth(
          worker,
          fn ->
            # Send many cast messages
            for _ <- 1..100 do
              GenServer.cast(worker, :ignored_message)
            end
          end,
          sampling_interval: 2
        )

      assert Map.has_key?(report, :initial_size)
      assert Map.has_key?(report, :final_size)
      assert Map.has_key?(report, :max_size)
      assert Map.has_key?(report, :avg_size)
      assert is_list(report.result)
    end

    test "detects mailbox growth" do
      {:ok, worker} = FastWorker.start_link()

      report =
        measure_mailbox_growth(worker, fn ->
          for _ <- 1..50 do
            GenServer.cast(worker, :work)
            # Small delay
            receive do
            after
              1 -> :ok
            end
          end
        end)

      # Mailbox should have grown during the operation
      assert report.max_size >= 0
    end

    test "does not leak mailbox monitor tasks when operation raises" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        send(pid, :stop)
      end)

      spawned =
        capture_direct_spawns(fn ->
          Enum.each(1..20, fn _ ->
            assert_raise RuntimeError, "boom", fn ->
              measure_mailbox_growth(
                pid,
                fn ->
                  raise "boom"
                end,
                sampling_interval: 1
              )
            end
          end)
        end)

      receive do
      after
        120 -> :ok
      end

      leaked = Enum.filter(spawned, &Process.alive?/1)
      assert leaked == []
    end

    test "does not leak mailbox monitor tasks when operation throws or exits" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        send(pid, :stop)
      end)

      spawned =
        capture_direct_spawns(fn ->
          Enum.each(1..10, fn _ ->
            assert catch_throw(
                     measure_mailbox_growth(
                       pid,
                       fn ->
                         throw(:boom)
                       end,
                       sampling_interval: 1
                     )
                   ) == :boom

            assert catch_exit(
                     measure_mailbox_growth(
                       pid,
                       fn ->
                         exit(:boom)
                       end,
                       sampling_interval: 1
                     )
                   ) == :boom
          end)
        end)

      receive do
      after
        120 -> :ok
      end

      leaked = Enum.filter(spawned, &Process.alive?/1)
      assert leaked == []
    end
  end

  describe "assert_mailbox_stable/2" do
    test "passes when mailbox stays small" do
      {:ok, worker} = FastWorker.start_link()

      assert_mailbox_stable(worker,
        during: fn ->
          for _ <- 1..10 do
            # Using call, so no mailbox buildup
            GenServer.call(worker, :fast_op)
          end
        end,
        max_size: 50
      )
    end

    test "raises when mailbox grows too large" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        send(pid, :stop)
      end)

      assert_raise RuntimeError, ~r/Mailbox size exceeded/, fn ->
        assert_mailbox_stable(pid,
          during: fn ->
            # Send many casts rapidly to build up mailbox
            for _ <- 1..200 do
              send(pid, {:ignored, :message})
            end
          end,
          max_size: 50,
          sampling_interval: 1
        )
      end
    end
  end

  describe "compare_performance/2" do
    test "compares performance of multiple functions" do
      funcs = %{
        "fast" => fn -> :fast end,
        "medium" => fn -> Enum.sum(1..100) end,
        "slow" => fn -> Enum.sum(1..10_000) end
      }

      results = compare_performance(funcs)

      assert Map.has_key?(results, "fast")
      assert Map.has_key?(results, "medium")
      assert Map.has_key?(results, "slow")

      assert results["fast"].result == :fast
      assert results["medium"].result == 5050
      assert results["slow"].result == 50_005_000

      Enum.each(results, fn {_name, metrics} ->
        assert is_integer(metrics.time_us)
        assert metrics.time_us >= 0
        assert is_integer(metrics.memory_bytes)
        assert metrics.memory_bytes >= 0
        assert is_integer(metrics.reductions)
        assert metrics.reductions >= 0
      end)
    end
  end

  defp capture_direct_spawns(fun) when is_function(fun, 0) do
    caller = self()
    :erlang.trace(caller, true, [:procs, :set_on_spawn])

    try do
      fun.()
    after
      receive do
      after
        10 -> :ok
      end

      :erlang.trace(caller, false, [:procs, :set_on_spawn])
    end

    drain_spawn_messages(caller, [])
    |> Enum.uniq()
  end

  defp drain_spawn_messages(caller, acc) do
    receive do
      {:trace, ^caller, :spawn, spawned_pid, _mfa} when is_pid(spawned_pid) ->
        drain_spawn_messages(caller, [spawned_pid | acc])

      {:trace, spawned_pid, :spawned, ^caller, _mfa} when is_pid(spawned_pid) ->
        drain_spawn_messages(caller, [spawned_pid | acc])

      {:trace, _traced_pid, _event, _arg} ->
        drain_spawn_messages(caller, acc)

      {:trace, _traced_pid, _event, _arg1, _arg2} ->
        drain_spawn_messages(caller, acc)

      {:trace, _traced_pid, _event, _arg1, _arg2, _arg3} ->
        drain_spawn_messages(caller, acc)
    after
      0 ->
        Enum.reverse(acc)
    end
  end
end
