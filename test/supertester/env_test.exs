defmodule Supertester.EnvTest do
  use ExUnit.Case, async: false

  defmodule FakeEnv do
    @behaviour Supertester.Env

    @impl true
    def on_exit(fun) when is_function(fun, 0) do
      send(self(), {:fake_env_called, fun})
      :ok
    end
  end

  setup do
    original = Application.get_env(:supertester, :env_module)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:supertester, :env_module)
        mod -> Application.put_env(:supertester, :env_module, mod)
      end
    end)

    :ok
  end

  test "delegates on_exit to configured environment module" do
    Application.put_env(:supertester, :env_module, FakeEnv)

    assert :ok = Supertester.Env.on_exit(fn -> :ok end)
    assert_received {:fake_env_called, fun}
    assert is_function(fun, 0)
  end

  test "setup_isolation registers cleanup via environment module" do
    Application.put_env(:supertester, :env_module, FakeEnv)

    {:ok, context} =
      Supertester.UnifiedTestFoundation.setup_isolation(:basic, %{test: :env_setup})

    assert match?(%Supertester.IsolationContext{}, context.isolation_context)
    assert_received {:fake_env_called, fun}
    assert is_function(fun, 0)
  end
end
