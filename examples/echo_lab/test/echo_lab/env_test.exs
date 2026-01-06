defmodule EchoLab.EnvTest do
  use ExUnit.Case, async: true

  alias EchoLab.TestEnv

  test "custom env module runs cleanup" do
    {:ok, _pid} = TestEnv.start_link()

    original = Application.get_env(:supertester, :env_module)

    try do
      Application.put_env(:supertester, :env_module, TestEnv)

      Supertester.Env.on_exit(fn -> send(self(), :cleanup_ran) end)
      TestEnv.run_callbacks()

      assert_received :cleanup_ran
    after
      if original do
        Application.put_env(:supertester, :env_module, original)
      else
        Application.delete_env(:supertester, :env_module)
      end

      TestEnv.stop()
    end
  end
end
