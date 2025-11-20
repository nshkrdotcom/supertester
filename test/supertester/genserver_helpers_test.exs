defmodule Supertester.GenServerHelpersTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Supertester.GenServerHelpers

  defmodule PlainServer do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{count: 0}, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}

    def handle_cast(:slow_increment, state) do
      Process.sleep(20)
      {:noreply, %{state | count: state.count + 1}}
    end

    @impl true
    def handle_call(:get, _from, state), do: {:reply, state.count, state}

    def handle_call({:slow_get, delay}, _from, state) do
      Process.sleep(delay)
      {:reply, state.count, state}
    end
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
    {:ok, server} = start_supervised(PlainServer)
    {:ok, no_sync} = start_supervised(NoSyncServer)
    %{server: server, no_sync: no_sync}
  end

  test "cast_and_sync raises when strict option is enabled", %{no_sync: server} do
    assert_raise ArgumentError, fn ->
      cast_and_sync(server, :ping, :__supertester_sync__, strict?: true)
    end
  end

  test "concurrent_calls returns structured successes and errors", %{server: server} do
    {:ok, results} =
      concurrent_calls(server, [{:slow_get, 5}, {:slow_get, 50}], 2, timeout: 20)

    assert [
             %{call: {:slow_get, 5}, successes: [0, 0], errors: []},
             %{call: {:slow_get, 50}, successes: [], errors: [:timeout, :timeout]}
           ] = results
  end

  test "stress_test_server reports aggregated metrics", %{server: server} do
    {:ok, report} =
      stress_test_server(server, [{:call, :get}, {:cast, :slow_increment}], 50, workers: 2)

    assert %{calls: calls, casts: casts, errors: errors, duration_ms: duration} = report
    assert calls + casts >= 0
    assert errors >= 0
    assert duration >= 50
  end
end
