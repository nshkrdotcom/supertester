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

        isolation_context = base_context.isolation_context

        isolation_context =
          if unquote(telemetry_isolation) do
            {:ok, _test_id, ctx} =
              Supertester.TelemetryHelpers.setup_telemetry_isolation(isolation_context)

            ctx
          else
            isolation_context
          end

        isolation_context =
          if unquote(logger_isolation) do
            {:ok, ctx} = Supertester.LoggerIsolation.setup_logger_isolation(isolation_context)

            if level = context[:logger_level] do
              Supertester.LoggerIsolation.isolate_level(level)
            end

            ctx
          else
            isolation_context
          end

        isolation_context =
          if unquote(ets_isolation) != [] do
            {:ok, ctx} =
              Supertester.ETSIsolation.setup_ets_isolation(
                isolation_context,
                unquote(ets_isolation)
              )

            ctx
          else
            isolation_context
          end

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

        {:ok, %{base_context | isolation_context: isolation_context}}
      end
    end
  end
end
