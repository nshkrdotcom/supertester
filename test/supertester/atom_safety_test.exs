defmodule Supertester.AtomSafetyTest do
  use ExUnit.Case, async: false

  alias Supertester.UnifiedTestFoundation

  defmodule NoopEnv do
    @behaviour Supertester.Env

    @impl true
    def on_exit(_callback), do: :ok
  end

  test "repeated isolation setup does not continuously allocate atoms" do
    original_env = Application.get_env(:supertester, :env_module)

    on_exit(fn ->
      if original_env do
        Application.put_env(:supertester, :env_module, original_env)
      else
        Application.delete_env(:supertester, :env_module)
      end
    end)

    Application.put_env(:supertester, :env_module, NoopEnv)

    {:ok, _} =
      UnifiedTestFoundation.setup_isolation(:basic, %{case: __MODULE__, test: :warmup_atom_safety})

    before = :erlang.system_info(:atom_count)

    for _ <- 1..30 do
      {:ok, _} =
        UnifiedTestFoundation.setup_isolation(:basic, %{case: __MODULE__, test: :repeated_setup})
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before < 40
  end

  test "ets table exhaustion simulation does not allocate one atom per table" do
    before = :erlang.system_info(:atom_count)
    {:ok, cleanup} = Supertester.ChaosHelpers.simulate_resource_exhaustion(:ets_tables, count: 20)
    cleanup.()
    after_count = :erlang.system_info(:atom_count)

    assert after_count - before < 5
  end
end
