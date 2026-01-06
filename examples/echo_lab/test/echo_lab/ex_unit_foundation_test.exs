defmodule EchoLab.ExUnitFoundationTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation,
    telemetry_isolation: true,
    logger_isolation: true,
    ets_isolation: [:echo_lab_table]

  alias Supertester.IsolationContext

  setup_all do
    table = :ets.new(:echo_lab_table, [:named_table, :public, :set])
    :ets.insert(table, {:seed, 1})

    optional = :ets.new(:echo_lab_optional_table, [:named_table, :public, :set])
    :ets.insert(optional, {:extra, 2})

    on_exit(fn ->
      if :ets.whereis(:echo_lab_table) != :undefined do
        :ets.delete(:echo_lab_table)
      end

      if :ets.whereis(:echo_lab_optional_table) != :undefined do
        :ets.delete(:echo_lab_optional_table)
      end
    end)

    :ok
  end

  @tag telemetry_events: [[:echo_lab, :auto]]
  @tag logger_level: :debug
  test "foundation wires isolation extensions", context do
    assert %IsolationContext{} = context.isolation_context
    assert IsolationContext.logger_isolated?(context.isolation_context)
    assert is_integer(IsolationContext.telemetry_id(context.isolation_context))

    {:ok, mirror} = Supertester.ETSIsolation.get_mirror(:echo_lab_table)
    assert :ets.info(mirror) != :undefined

    Supertester.TelemetryHelpers.emit_with_context([:echo_lab, :auto], %{value: 1}, %{})

    assert_receive {:telemetry, [:echo_lab, :auto], %{value: 1}, metadata}
    assert metadata[:supertester_test_id]

    assert Logger.get_process_level(self()) == :debug
  end

  @tag ets_tables: [:echo_lab_optional_table]
  test "per-test ets mirror tag works", _context do
    {:ok, mirror} = Supertester.ETSIsolation.get_mirror(:echo_lab_optional_table)
    assert :ets.info(mirror) != :undefined
  end
end
