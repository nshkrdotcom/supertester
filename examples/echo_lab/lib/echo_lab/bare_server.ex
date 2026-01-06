defmodule EchoLab.BareServer do
  @moduledoc """
  GenServer without Supertester sync support to demonstrate strict cast handling.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{pings: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, %{state | pings: state.pings + 1}}
  end

  def handle_call(_message, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(_message, state) do
    {:noreply, state}
  end
end
