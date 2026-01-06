defmodule EchoLab.UnifiedTestFoundationAsyncTest do
  use ExUnit.Case, async: true

  alias Supertester.UnifiedTestFoundation

  test "setup isolation modes and context helpers" do
    Enum.each([:basic, :registry, :full_isolation], fn mode ->
      {:ok, context} = UnifiedTestFoundation.setup_isolation(mode, %{test: mode})
      assert context.isolation_context.tags[:isolation] == mode
    end)

    {:ok, context} = UnifiedTestFoundation.setup_isolation(:basic, %{test: :basic})
    assert UnifiedTestFoundation.fetch_isolation_context()

    stored = UnifiedTestFoundation.put_isolation_context(context.isolation_context)
    assert stored == context.isolation_context

    updated =
      context.isolation_context
      |> UnifiedTestFoundation.add_tracked_process(%{pid: self(), name: nil, module: __MODULE__})
      |> UnifiedTestFoundation.add_tracked_ets_table(:table)
      |> UnifiedTestFoundation.add_cleanup_callback(fn -> :ok end)

    assert length(updated.processes) == 1
    assert updated.ets_tables == [:table]
    assert length(updated.cleanup_callbacks) == 1

    assert UnifiedTestFoundation.isolation_allows_async?(:basic)
    assert UnifiedTestFoundation.isolation_allows_async?(:full_isolation)
    assert UnifiedTestFoundation.isolation_timeout(:basic) == 5_000
  end

  test "verify_test_isolation and supervision readiness" do
    ctx = %Supertester.IsolationContext{
      test_id: :demo,
      processes: [%{pid: self(), name: nil, module: __MODULE__}]
    }

    assert UnifiedTestFoundation.verify_test_isolation(%{isolation_context: ctx})

    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    assert {:ok, ^supervisor} =
             UnifiedTestFoundation.wait_for_supervision_tree_ready(supervisor, 50)
  end
end
