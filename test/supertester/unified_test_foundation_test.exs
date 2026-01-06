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
  require Supertester.ExUnitFoundation
  require Supertester.UnifiedTestFoundation

  test "legacy macro warns and delegates to ExUnitFoundation" do
    warning =
      capture_io(:stderr, fn ->
        expanded =
          Macro.expand_once(
            quote(do: Supertester.UnifiedTestFoundation.__using__(isolation: :basic)),
            __ENV__
          )

        assert uses_module?(expanded, Supertester.ExUnitFoundation)
      end)

    assert warning =~ "Supertester.UnifiedTestFoundation now only manages isolation"
  end

  test "ex_unit adapter disables async for strict isolation modes" do
    expanded =
      Macro.expand_once(
        quote(do: Supertester.ExUnitFoundation.__using__(isolation: :contamination_detection)),
        __ENV__
      )

    refute ex_unit_async?(expanded)
  end

  defp uses_module?(ast, module) when is_atom(module) do
    module_parts = module |> Module.split() |> Enum.map(&String.to_atom/1)

    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _meta, [{:__aliases__, _aliases_meta, ^module_parts} | _]} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp ex_unit_async?(ast) do
    {_ast, async?} =
      Macro.prewalk(ast, nil, fn
        {:use, _meta, [{:__aliases__, _aliases_meta, [:ExUnit, :Case]}, opts]} = node, _acc ->
          {node, Keyword.get(opts, :async)}

        node, acc ->
          {node, acc}
      end)

    async?
  end
end
