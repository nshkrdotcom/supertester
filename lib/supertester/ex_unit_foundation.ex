defmodule Supertester.ExUnitFoundation do
  @moduledoc """
  Thin ExUnit adapter that wires `Supertester.UnifiedTestFoundation` into `ExUnit.Case`.

  Use this module from your test cases to enable Supertester isolation while keeping
  the ergonomics of `use ExUnit.Case`. All isolation options supported by
  `Supertester.UnifiedTestFoundation` are available via the `:isolation` option.

  ## Example

      defmodule MyApp.MyTest do
        use Supertester.ExUnitFoundation, isolation: :full_isolation

        test "works concurrently", context do
          assert context.isolation_context.test_id
        end
      end
  """

  @doc false
  defmacro __using__(opts) do
    isolation = Keyword.get(opts, :isolation, :basic)
    async? = Supertester.UnifiedTestFoundation.isolation_allows_async?(isolation)

    quote do
      use ExUnit.Case, async: unquote(async?)

      setup context do
        Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)
      end
    end
  end
end
