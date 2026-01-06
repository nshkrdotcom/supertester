defmodule EchoLab.TestEnv do
  @moduledoc false
  @behaviour Supertester.Env

  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl true
  def on_exit(callback) when is_function(callback, 0) do
    Agent.update(__MODULE__, fn callbacks -> [callback | callbacks] end)
    :ok
  end

  def run_callbacks do
    callbacks =
      Agent.get_and_update(__MODULE__, fn callbacks -> {Enum.reverse(callbacks), []} end)

    Enum.each(callbacks, fn callback -> callback.() end)
    :ok
  end

  def stop do
    Agent.stop(__MODULE__)
    :ok
  end
end
