defmodule Supertester.ConcurrentHarnessTest do
  use ExUnit.Case, async: true

  alias Supertester.ConcurrentHarness
  alias Supertester.GenServerHelpers

  defmodule CounterServer do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{count: 0}, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}
    def handle_cast(:decrement, state), do: {:noreply, %{state | count: state.count - 1}}

    @impl true
    def handle_call(:value, _from, state), do: {:reply, state.count, state}
  end

  test "simple scenario executes threads and honors invariant" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:cast, :increment}, {:cast, :decrement}, {:call, :value}],
        3,
        invariant: fn server, ctx ->
          {:ok, state} = GenServerHelpers.get_server_state_safely(server)
          assert is_map(state)
          assert is_integer(state.count)
          assert ctx.metrics.total_operations > 0
        end,
        metadata: %{purpose: :counter}
      )

    assert {:ok, report} = ConcurrentHarness.run(scenario)

    assert report.metadata.purpose == :counter
    assert report.metrics.total_operations == length(report.events)
    assert Enum.all?(report.events, fn event -> match?({:ok, _}, event.result) end)
  end

  test "scenario can collect mailbox metrics" do
    scenario = %{
      setup: fn -> CounterServer.start_link([]) end,
      threads: [
        [{:cast, :increment}, {:cast, :increment}]
      ],
      timeout_ms: 1_000,
      invariant: fn _, _ -> :ok end,
      mailbox: [sampling_interval: 1]
    }

    assert {:ok, report} = ConcurrentHarness.run(scenario)
    assert report.metrics.mailbox_observed?
    assert %{max_size: _} = report.mailbox
  end

  test "failing invariant surfaces structured error" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:call, :value}],
        1,
        invariant: fn _, _ -> false end
      )

    assert {:error, {:invariant_failed, :returned_false}} = ConcurrentHarness.run(scenario)
  end

  test "default cleanup stops the subject even when invariant fails" do
    parent = self()

    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:call, :value}],
        1,
        setup: fn ->
          {:ok, pid} = CounterServer.start_link([])
          send(parent, {:subject, pid})
          {:ok, pid, %{}}
        end,
        invariant: fn _, _ -> false end
      )

    assert {:error, {:invariant_failed, :returned_false}} = ConcurrentHarness.run(scenario)
    assert_receive {:subject, pid}
    refute Process.alive?(pid)
  end

  test "default cleanup stops the subject even when a thread times out" do
    parent = self()

    scenario = %{
      setup: fn ->
        {:ok, pid} = CounterServer.start_link([])
        send(parent, {:subject_timeout_case, pid})
        {:ok, pid, %{}}
      end,
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
    assert_receive {:subject_timeout_case, pid}
    refute Process.alive?(pid)
  end

  test "chaos hook runs alongside scenario" do
    parent = self()

    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:cast, :increment}],
        2,
        chaos: fn server, ctx ->
          send(parent, {:chaos, ctx.metadata.scenario_id})
          GenServer.cast(server, :increment)
          :chaos_done
        end,
        invariant: fn _, _ -> :ok end
      )

    assert {:ok, report} = ConcurrentHarness.run(scenario)
    assert_receive {:chaos, scenario_id}
    assert report.metadata.scenario_id == scenario_id
    assert report.chaos.result == :chaos_done
    assert is_integer(report.chaos.duration_ms)
  end

  test "performance expectations enforce limits" do
    scenario = %{
      setup: fn -> CounterServer.start_link([]) end,
      threads: [
        [{:call, :value}]
      ],
      timeout_ms: 1_000,
      invariant: fn _, _ -> :ok end,
      performance_expectations: [max_time_ms: 0]
    }

    assert {:error, {:performance_failed, %{error: %RuntimeError{}}}} =
             ConcurrentHarness.run(scenario)
  end

  test "run_with_performance returns scenario result" do
    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:call, :value}],
        1,
        invariant: fn _, _ -> :ok end
      )

    assert {:ok, _report} =
             ConcurrentHarness.run_with_performance(scenario,
               max_time_ms: 100,
               max_memory_bytes: 10_000_000
             )
  end

  test "telemetry events fire for scenario lifecycle" do
    handler_id = "concurrent-harness-test"

    events = [
      [:supertester, :concurrent, :scenario, :start],
      [:supertester, :concurrent, :scenario, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &Supertester.ConcurrentHarnessTest.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    scenario =
      ConcurrentHarness.simple_genserver_scenario(
        CounterServer,
        [{:call, :value}],
        1,
        invariant: fn _, _ -> :ok end
      )

    assert {:ok, _report} = ConcurrentHarness.run(scenario)

    assert_receive {:telemetry, [:supertester, :concurrent, :scenario, :start], _meas, metadata}
    assert Map.has_key?(metadata, :scenario_id)

    assert_receive {:telemetry, [:supertester, :concurrent, :scenario, :stop], meas,
                    stop_metadata}

    assert meas.duration_ms >= 0
    assert meas.status in [:ok, :error]
    assert Map.has_key?(stop_metadata, :scenario_id)
  end

  def handle_telemetry(event, measurements, metadata, caller) do
    send(caller, {:telemetry, event, measurements, metadata})
  end
end
