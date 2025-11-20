if Code.ensure_loaded?(StreamData) do
  defmodule Supertester.PropertyHelpersTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Supertester.ConcurrentHarness
    alias Supertester.PropertyHelpers

    defmodule TargetServer do
      use GenServer
      use Supertester.TestableGenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, %{count: Keyword.get(opts, :count, 0)}, opts)
      end

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}
      def handle_cast(:decrement, state), do: {:noreply, %{state | count: state.count - 1}}

      @impl true
      def handle_call(:value, _from, state), do: {:reply, state.count, state}
    end

    test "genserver_operation_sequence normalizes ops" do
      generator =
        PropertyHelpers.genserver_operation_sequence(
          [:ping, {:cast, :increment}, {:call, :value}],
          default_operation: :cast,
          min_length: 1,
          max_length: 3
        )

      check all(seq <- generator, max_runs: 10) do
        assert Enum.all?(seq, fn
                 {:cast, _} -> true
                 {:call, _} -> true
                 {:custom, _} -> true
               end)
      end
    end

    test "concurrent scenarios run through the harness" do
      generator =
        PropertyHelpers.concurrent_scenario(
          operations: [{:cast, :increment}, {:cast, :decrement}, {:call, :value}],
          min_threads: 1,
          max_threads: 2,
          min_ops_per_thread: 1,
          max_ops_per_thread: 3
        )

      check all(cfg <- generator, max_runs: 5) do
        scenario =
          ConcurrentHarness.from_property_config(TargetServer, cfg, invariant: fn _, _ -> :ok end)

        assert {:ok, _report} = ConcurrentHarness.run(scenario)
      end
    end
  end
else
  defmodule Supertester.PropertyHelpersTest do
    use ExUnit.Case

    test "StreamData not available - property helpers skipped" do
      assert true
    end
  end
end
