defmodule Supertester.TestableGenServerTest do
  use ExUnit.Case, async: true

  defmodule SimpleServer do
    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @impl true
    def init(:ok) do
      {:ok, %{count: 0}}
    end

    @impl true
    def handle_call(:get_count, _from, state) do
      {:reply, state.count, state}
    end

    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | count: state.count + 1}}
    end

    @impl true
    def handle_cast(:increment, state) do
      {:noreply, %{state | count: state.count + 1}}
    end

    # TestableGenServer should inject __supertester_sync__ handler
  end

  describe "TestableGenServer behavior" do
    test "injects __supertester_sync__ handler that returns :ok" do
      {:ok, server} = SimpleServer.start_link()

      # Should be able to call the sync message
      assert :ok = GenServer.call(server, :__supertester_sync__)
    end

    test "sync handler doesn't affect normal operation" do
      {:ok, server} = SimpleServer.start_link()

      assert 0 = GenServer.call(server, :get_count)
      assert :ok = GenServer.call(server, :increment)
      assert 1 = GenServer.call(server, :get_count)
    end

    test "sync handler works after casts" do
      {:ok, server} = SimpleServer.start_link()

      # Cast some operations
      GenServer.cast(server, :increment)
      GenServer.cast(server, :increment)

      # Sync ensures casts are processed
      assert :ok = GenServer.call(server, :__supertester_sync__)

      # State should be updated
      assert 2 = GenServer.call(server, :get_count)
    end

    test "sync handler returns current state when :return_state option is true" do
      {:ok, server} = SimpleServer.start_link()

      GenServer.call(server, :increment)

      # Should return state when requested
      assert {:ok, %{count: 1}} =
               GenServer.call(server, {:__supertester_sync__, return_state: true})
    end
  end
end
