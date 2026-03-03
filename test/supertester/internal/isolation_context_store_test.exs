defmodule Supertester.Internal.IsolationContextStoreTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.IsolationContextStore
  alias Supertester.{IsolationContext, UnifiedTestFoundation}

  setup do
    previous = UnifiedTestFoundation.fetch_isolation_context()
    UnifiedTestFoundation.put_isolation_context(nil)

    on_exit(fn ->
      UnifiedTestFoundation.put_isolation_context(previous)
    end)

    :ok
  end

  test "update/1 returns nil when context is not set" do
    assert IsolationContextStore.update(fn ctx -> ctx end) == nil
  end

  test "put_updated/2 updates and stores the provided context" do
    ctx = %IsolationContext{test_id: :store_test, tags: %{suite: :internal}}

    updated =
      IsolationContextStore.put_updated(ctx, fn context ->
        %{context | tags: Map.put(context.tags, :case, :put_updated)}
      end)

    assert updated.tags.case == :put_updated
    assert UnifiedTestFoundation.fetch_isolation_context() == updated
  end
end
