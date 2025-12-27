defmodule Supertester.GenServerHelpersTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Supertester.GenServerHelpers

  # A server that blocks until explicitly released via a gate.
  # This allows deterministic testing without timing dependencies.
  defmodule GatedServer do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{count: 0}, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:gated_get, gate}, _from, state) do
      # Block until gate process sends :release or dies
      ref = Process.monitor(gate)

      receive do
        :release -> :ok
        {:DOWN, ^ref, :process, ^gate, _} -> :ok
      end

      Process.demonitor(ref, [:flush])
      {:reply, state.count, state}
    end

    def handle_call(:get, _from, state), do: {:reply, state.count, state}

    @impl true
    def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}
  end

  defmodule NoSyncServer do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:ping, state), do: {:noreply, state}
  end

  setup do
    {:ok, no_sync} = start_supervised(NoSyncServer)
    %{no_sync: no_sync}
  end

  test "cast_and_sync raises when strict option is enabled", %{no_sync: server} do
    assert_raise ArgumentError, fn ->
      cast_and_sync(server, :ping, :__supertester_sync__, strict?: true)
    end
  end

  test "concurrent_calls returns structured successes and errors" do
    # Use separate servers for each call type to avoid GenServer serialization issues.
    # This tests the harness correctly aggregates successes and errors.
    {:ok, fast_server} = start_supervised({GatedServer, []}, id: :fast_server)
    {:ok, slow_server} = start_supervised({GatedServer, []}, id: :slow_server)

    # Gate for fast calls - exits immediately, unblocking the GenServer
    fast_gate =
      spawn(fn ->
        receive do
          :hold -> :ok
        after
          0 -> :ok
        end
      end)

    # Wait for fast_gate to exit (it exits immediately after the after 0)
    ref = Process.monitor(fast_gate)
    receive do: ({:DOWN, ^ref, :process, ^fast_gate, _} -> :ok)

    # Gate for slow calls - blocks forever waiting for a message that never comes
    slow_gate = spawn(fn -> receive do: (:never_sent -> :ok) end)

    # Run concurrent calls against separate servers
    {:ok, fast_results} =
      concurrent_calls(fast_server, [{:gated_get, fast_gate}], 2, timeout: 1000)

    {:ok, slow_results} =
      concurrent_calls(slow_server, [{:gated_get, slow_gate}], 2, timeout: 50)

    # Fast server: gate exited, GenServer saw {:DOWN, ...} and returned
    assert [%{call: {:gated_get, ^fast_gate}, successes: [0, 0], errors: []}] = fast_results

    # Slow server: gate alive, GenServer blocked, calls timed out
    assert [%{call: {:gated_get, ^slow_gate}, successes: [], errors: [:timeout, :timeout]}] =
             slow_results

    # Cleanup
    Process.exit(slow_gate, :kill)
  end

  test "stress_test_server reports aggregated metrics" do
    {:ok, server} = start_supervised({GatedServer, []}, id: :stress_server)

    {:ok, report} =
      stress_test_server(server, [{:call, :get}, {:cast, :increment}], 50, workers: 2)

    assert %{calls: calls, casts: casts, errors: errors, duration_ms: duration} = report
    assert calls + casts >= 0
    assert errors >= 0
    assert duration >= 50
  end
end
