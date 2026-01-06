defmodule EchoLab.UnifiedTestFoundationContaminationTest do
  use ExUnit.Case, async: false

  alias Supertester.UnifiedTestFoundation

  test "contamination detection runs in sync mode" do
    {:ok, _pid} = EchoLab.TestEnv.start_link()
    original = Application.get_env(:supertester, :env_module)

    try do
      Application.put_env(:supertester, :env_module, EchoLab.TestEnv)

      {:ok, context} =
        UnifiedTestFoundation.setup_isolation(:contamination_detection, %{test: :contamination})

      updated = %{
        context.isolation_context
        | initial_processes: Process.list(),
          initial_ets_tables: :ets.all()
      }

      UnifiedTestFoundation.put_isolation_context(updated)
      EchoLab.TestEnv.run_callbacks()

      assert context.isolation_context.tags[:isolation] == :contamination_detection
      refute UnifiedTestFoundation.isolation_allows_async?(:contamination_detection)
      assert UnifiedTestFoundation.isolation_timeout(:contamination_detection) == 30_000
    after
      if original do
        Application.put_env(:supertester, :env_module, original)
      else
        Application.delete_env(:supertester, :env_module)
      end

      EchoLab.TestEnv.stop()
    end
  end
end
