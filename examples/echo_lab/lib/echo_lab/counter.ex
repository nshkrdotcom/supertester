defmodule EchoLab.Counter do
  @moduledoc """
  Simple counter GenServer used by the example test suite.
  """

  use GenServer
  use Supertester.TestableGenServer

  @type state :: %{count: integer(), history: [term()]}

  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :initial, 0)
    GenServer.start_link(__MODULE__, %{count: initial, history: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  def increment(server, amount \\ 1) do
    GenServer.cast(server, {:increment, amount})
  end

  def decrement(server, amount \\ 1) do
    GenServer.cast(server, {:decrement, amount})
  end

  def add(server, amount) do
    GenServer.call(server, {:add, amount})
  end

  def value(server) do
    GenServer.call(server, :value)
  end

  @impl true
  def handle_cast({:increment, amount}, state) do
    {:noreply, update(state, amount, :inc)}
  end

  def handle_cast({:decrement, amount}, state) do
    {:noreply, update(state, -amount, :dec)}
  end

  @impl true
  def handle_call(:value, _from, state) do
    {:reply, state.count, state}
  end

  def handle_call({:add, amount}, _from, state) do
    new_state = update(state, amount, :call_add)
    {:reply, new_state.count, new_state}
  end

  def handle_call(:crash, _from, state) do
    {:stop, :crash, :ok, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  defp update(state, amount, tag) do
    %{
      state
      | count: state.count + amount,
        history: [{tag, amount} | state.history]
    }
  end
end
