defmodule EchoLab.Worker do
  @moduledoc """
  Simple worker GenServer used by supervisor examples.
  """

  use GenServer
  use Supertester.TestableGenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, %{name: name, work: 0}, name: name)
  end

  @impl true
  def init(state), do: {:ok, state}

  def ping(server), do: GenServer.call(server, :ping)
  def work(server), do: GenServer.cast(server, :work)

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call(:crash, _from, state) do
    {:stop, :crash, :ok, state}
  end

  @impl true
  def handle_cast(:work, state) do
    {:noreply, %{state | work: state.work + 1}}
  end
end
