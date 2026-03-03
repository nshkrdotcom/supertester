defmodule Supertester.Internal.IsolationContextStore do
  @moduledoc false

  alias Supertester.{IsolationContext, UnifiedTestFoundation}

  @spec update((IsolationContext.t() -> IsolationContext.t())) :: IsolationContext.t() | nil
  def update(fun) when is_function(fun, 1) do
    case UnifiedTestFoundation.fetch_isolation_context() do
      %IsolationContext{} = ctx ->
        updated_ctx = fun.(ctx)
        UnifiedTestFoundation.put_isolation_context(updated_ctx)
        updated_ctx

      _ ->
        nil
    end
  end

  @spec put_updated(IsolationContext.t(), (IsolationContext.t() -> IsolationContext.t())) ::
          IsolationContext.t()
  def put_updated(%IsolationContext{} = ctx, fun) when is_function(fun, 1) do
    updated_ctx = fun.(ctx)
    UnifiedTestFoundation.put_isolation_context(updated_ctx)
    updated_ctx
  end
end
