defmodule Supertester.ExUnitFoundationAsyncCase do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  test "async config matches allowed isolation and sets context", context do
    assert __MODULE__.__ex_unit__(:config).async?
    assert match?(%Supertester.IsolationContext{}, context.isolation_context)
    assert context.module == __MODULE__
  end
end

defmodule Supertester.UnifiedTestFoundationDeprecationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "legacy macro warns and still registers an ExUnit case" do
    mod = Module.concat(__MODULE__, :LegacyCase)

    warning =
      capture_io(:stderr, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(mod) do
              use Supertester.UnifiedTestFoundation, isolation: :basic
            end
          end
        )
      end)

    assert warning =~ "Supertester.UnifiedTestFoundation now only manages isolation"
    assert function_exported?(mod, :__ex_unit__, 1)
    assert mod.__ex_unit__(:config).async?
  end

  test "ex_unit adapter disables async for strict isolation modes" do
    mod = Module.concat(__MODULE__, :StrictCase)

    Code.compile_quoted(
      quote do
        defmodule unquote(mod) do
          use Supertester.ExUnitFoundation, isolation: :contamination_detection
        end
      end
    )

    refute mod.__ex_unit__(:config).async?
  end
end
