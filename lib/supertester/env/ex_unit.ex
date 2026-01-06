defmodule Supertester.Env.ExUnit do
  @moduledoc false
  @behaviour Supertester.Env

  alias Elixir.ExUnit.Callbacks, as: ExUnitCallbacks

  @impl true
  def on_exit(callback) when is_function(callback, 0) do
    ExUnitCallbacks.on_exit(callback)
  end
end
