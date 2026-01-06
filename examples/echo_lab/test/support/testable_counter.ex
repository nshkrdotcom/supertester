defmodule EchoLab.TestableCounter do
  @moduledoc false

  use GenServer
  use Supertester.TestableGenServer

  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :initial, 0)
    GenServer.start_link(__MODULE__, %{count: initial}, opts)
  end

  def increment(server), do: GenServer.cast(server, :increment)
  def value(server), do: GenServer.call(server, :value)
  def add(server, amount), do: GenServer.call(server, {:add, amount})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:increment, state) do
    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def handle_call(:value, _from, state) do
    {:reply, state.count, state}
  end

  def handle_call({:add, amount}, _from, state) do
    new_state = %{state | count: state.count + amount}
    {:reply, new_state.count, new_state}
  end

  def handle_call(:crash, _from, state) do
    {:stop, :crash, :ok, state}
  end
end
