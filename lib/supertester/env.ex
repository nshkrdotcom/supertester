defmodule Supertester.Env do
  @moduledoc """
  Environment abstraction that Supertester uses to integrate with the host test runner.

  By default, `Supertester.Env` delegates to `ExUnit.Callbacks.on_exit/1`. Custom harnesses
  can provide their own implementation via the `:supertester, :env_module` application
  configuration.
  """

  @callback on_exit((-> any())) :: :ok

  @doc """
  Registers a callback to run when the current test finishes.
  """
  @spec on_exit((-> any())) :: :ok
  def on_exit(callback) when is_function(callback, 0) do
    impl().on_exit(callback)
  end

  defp impl do
    Application.get_env(:supertester, :env_module, Supertester.Env.ExUnit)
  end

  defmodule ExUnit do
    @moduledoc false
    @behaviour Supertester.Env

    @impl true
    def on_exit(callback) when is_function(callback, 0) do
      apply(Elixir.ExUnit.Callbacks, :on_exit, [callback])
    end
  end
end
