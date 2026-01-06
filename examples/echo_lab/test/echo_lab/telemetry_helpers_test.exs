defmodule EchoLab.TelemetryHelpersTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.TelemetryHelpers

  alias EchoLab.TelemetryEmitter

  setup context do
    {:ok, test_id, ctx} = setup_telemetry_isolation(context.isolation_context)
    flush_telemetry(:all)
    {:ok, %{test_id: test_id, isolation_context: ctx}}
  end

  test "setup_telemetry_isolation and accessors", %{test_id: test_id} do
    assert get_test_id() == test_id
    assert get_test_id!() == test_id
    assert current_test_metadata()[:supertester_test_id] == test_id
    assert current_test_metadata(%{extra: true})[:extra]
  end

  test "attach_isolated delivers events" do
    {:ok, _handler} = attach_isolated([[:echo_lab, :event]])

    TelemetryEmitter.emit([:echo_lab, :event], %{value: 1}, current_test_metadata())

    assert_telemetry([:echo_lab, :event])
  end

  test "attach_isolated passthrough and transform" do
    {:ok, _handler} =
      attach_isolated([[:echo_lab, :passthrough]],
        passthrough: true,
        transform: fn {:telemetry, event, measurements, metadata} ->
          {:delivered, event, measurements, metadata}
        end
      )

    TelemetryEmitter.emit([:echo_lab, :passthrough], %{value: 2}, %{})

    assert_receive {:delivered, [:echo_lab, :passthrough], %{value: 2}, _}
  end

  test "assert_telemetry_count and refute_telemetry" do
    {:ok, _handler} = attach_isolated([[:echo_lab, :count]])

    TelemetryEmitter.emit([:echo_lab, :count], %{}, current_test_metadata())
    TelemetryEmitter.emit([:echo_lab, :count], %{}, current_test_metadata())

    events = assert_telemetry_count([:echo_lab, :count], 2)
    assert length(events) == 2

    refute_telemetry([:echo_lab, :missing], timeout: 10)
  end

  test "flush_telemetry and with_telemetry buffer" do
    {:ok, _handler} = attach_isolated([[:echo_lab, :flush]])
    TelemetryEmitter.emit([:echo_lab, :flush], %{}, current_test_metadata())

    assert length(flush_telemetry([:echo_lab, :flush])) == 1

    {result, buffered} =
      with_telemetry([[:echo_lab, :buffered]], fn ->
        emit_with_context([:echo_lab, :buffered], %{value: 3}, %{})
        :ok
      end)

    assert result == :ok
    assert length(buffered) == 1
  end
end
