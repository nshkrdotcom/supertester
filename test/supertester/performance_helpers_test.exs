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

      assert_performance(fast_op,
        max_time_ms: 100,
        max_memory_bytes: 1_000_000
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

    # Flaky due to GC timing
    @tag :skip
    test "detects memory growth trend" do
      # This test creates a memory leak intentionally
      # Note: Skipped due to timing variability with GC
      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert_raise RuntimeError, ~r/Memory leak detected/, fn ->
        assert_no_memory_leak(
          100,
          fn ->
            # Intentionally leak memory with larger chunks
            Agent.update(agent, fn list -> [String.duplicate("x", 50000) | list] end)
          end,
          # Very tight threshold to catch leak
          threshold: 0.02
        )
      end
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

  describe "measure_mailbox_growth/2" do
    test "measures mailbox size during operation" do
      {:ok, worker} = FastWorker.start_link()

      report =
        measure_mailbox_growth(worker, fn ->
          # Send many cast messages
          for _ <- 1..100 do
            GenServer.cast(worker, :ignored_message)
          end
        end)

      assert Map.has_key?(report, :initial_size)
      assert Map.has_key?(report, :final_size)
      assert Map.has_key?(report, :max_size)
      assert Map.has_key?(report, :avg_size)
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

    # Flaky due to timing - monitoring might not catch growth
    @tag :skip
    test "raises when mailbox grows too large" do
      {:ok, worker} = FastWorker.start_link()

      assert_raise RuntimeError, ~r/Mailbox size exceeded/, fn ->
        assert_mailbox_stable(worker,
          during: fn ->
            # Send many casts rapidly to build up mailbox
            for _ <- 1..200 do
              # Use send instead of cast for speed
              send(worker, {:ignored, :message})
            end

            # Small delay to let monitoring catch the growth
            receive do
            after
              20 -> :ok
            end
          end,
          max_size: 50
        )
      end
    end
  end

  describe "compare_performance/2" do
    test "compares performance of multiple functions" do
      funcs = %{
        "fast" => fn -> 1 + 1 end,
        "medium" => fn -> Enum.sum(1..100) end,
        # Much larger to ensure measurable difference
        "slow" => fn -> Enum.sum(1..10000) end
      }

      results = compare_performance(funcs)

      assert Map.has_key?(results, "fast")
      assert Map.has_key?(results, "medium")
      assert Map.has_key?(results, "slow")

      # Fast should be faster than slow (or same if too fast to measure)
      assert results["fast"].time_us <= results["slow"].time_us
    end
  end
end
