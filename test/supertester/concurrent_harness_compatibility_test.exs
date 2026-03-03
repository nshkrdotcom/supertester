defmodule Supertester.ConcurrentHarnessCompatibilityTest do
  use ExUnit.Case, async: true

  alias Supertester.ConcurrentHarness

  defmodule CompatServer do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{count: 0}, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:value, _from, state), do: {:reply, state.count, state}

    @impl true
    def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}
  end

  test "run/1 report contract stays stable" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CompatServer,
        [{:cast, :increment}, {:call, :value}],
        2,
        invariant: fn _, _ -> :ok end
      )

    assert {:ok, report} = ConcurrentHarness.run(scenario)
    assert Map.has_key?(report, :events)
    assert Map.has_key?(report, :threads)
    assert Map.has_key?(report, :metrics)
    assert Map.has_key?(report, :mailbox)
    assert Map.has_key?(report, :chaos)
    assert Map.has_key?(report, :performance)
    assert Map.has_key?(report, :metadata)
    assert Map.has_key?(report, :context)
    assert Map.has_key?(report.metrics, :duration_ms)
    assert Map.has_key?(report.metrics, :total_operations)
    assert Map.has_key?(report.metrics, :thread_count)
    assert Map.has_key?(report.metrics, :operation_errors)
    assert Map.has_key?(report.metrics, :overall_duration_ms)
    assert Map.has_key?(report.metrics, :mailbox_observed?)
  end

  test "thread timeout failures preserve error tuple shape" do
    scenario = %{
      setup: fn -> CompatServer.start_link([]) end,
      threads: [
        [
          {:custom,
           fn _subject ->
             receive do
             after
               200 -> :ok
             end
           end}
        ]
      ],
      timeout_ms: 20,
      invariant: fn _, _ -> :ok end
    }

    assert {:error, {:thread_failure, {:error, :timeout}}} = ConcurrentHarness.run(scenario)
  end

  test "cleanup failures continue wrapping existing run errors" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CompatServer,
        [{:call, :value}],
        1,
        invariant: fn _, _ -> false end,
        cleanup: fn _, _ -> raise "cleanup boom" end
      )

    assert {:error,
            {:cleanup_failed, {:cleanup_failed, {%RuntimeError{message: "cleanup boom"}, _}},
             {:invariant_failed, :returned_false}}} = ConcurrentHarness.run(scenario)
  end

  test "run_with_performance/2 preserves run return contract" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CompatServer,
        [{:call, :value}],
        1,
        invariant: fn _, _ -> :ok end
      )

    assert {:ok, report} =
             ConcurrentHarness.run_with_performance(scenario,
               max_time_ms: 100,
               max_memory_bytes: 10_000_000
             )

    assert is_list(report.events)
    assert is_list(report.threads)
  end
end
