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
    telemetry_isolation = Keyword.get(opts, :telemetry_isolation, false)
    logger_isolation = Keyword.get(opts, :logger_isolation, false)
    ets_isolation = Keyword.get(opts, :ets_isolation, [])
    async? = Supertester.UnifiedTestFoundation.isolation_allows_async?(isolation)

    quote do
      use ExUnit.Case, async: unquote(async?)

      setup context do
        {:ok, base_context} =
          Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)

        isolation_context =
          base_context.isolation_context
          |> Supertester.ExUnitFoundation.maybe_setup_telemetry(unquote(telemetry_isolation))
          |> Supertester.ExUnitFoundation.maybe_setup_logger(unquote(logger_isolation), context)
          |> Supertester.ExUnitFoundation.maybe_setup_ets(unquote(ets_isolation))

        Supertester.ExUnitFoundation.maybe_attach_runtime_overrides(context)

        {:ok, %{base_context | isolation_context: isolation_context}}
      end
    end
  end

  @doc false
  @spec maybe_setup_telemetry(Supertester.IsolationContext.t(), boolean()) ::
          Supertester.IsolationContext.t()
  def maybe_setup_telemetry(isolation_context, false), do: isolation_context

  def maybe_setup_telemetry(isolation_context, true) do
    {:ok, _test_id, ctx} =
      Supertester.TelemetryHelpers.setup_telemetry_isolation(isolation_context)

    ctx
  end

  @doc false
  @spec maybe_setup_logger(Supertester.IsolationContext.t(), boolean(), map()) ::
          Supertester.IsolationContext.t()
  def maybe_setup_logger(isolation_context, false, _context), do: isolation_context

  def maybe_setup_logger(isolation_context, true, context) do
    {:ok, ctx} = Supertester.LoggerIsolation.setup_logger_isolation(isolation_context)

    if level = context[:logger_level] do
      Supertester.LoggerIsolation.isolate_level(level)
    end

    ctx
  end

  @doc false
  @spec maybe_setup_ets(Supertester.IsolationContext.t(), [atom()]) ::
          Supertester.IsolationContext.t()
  def maybe_setup_ets(isolation_context, []), do: isolation_context

  def maybe_setup_ets(isolation_context, tables) when is_list(tables) do
    {:ok, ctx} = Supertester.ETSIsolation.setup_ets_isolation(isolation_context, tables)
    ctx
  end

  @doc false
  @spec maybe_attach_runtime_overrides(map()) :: :ok
  def maybe_attach_runtime_overrides(context) when is_map(context) do
    if events = context[:telemetry_events] do
      Supertester.TelemetryHelpers.attach_isolated(events)
    end

    if tables = context[:ets_tables] do
      tables
      |> List.wrap()
      |> Enum.each(fn table ->
        {:ok, _} = Supertester.ETSIsolation.mirror_table(table)
      end)
    end

    :ok
  end
end
