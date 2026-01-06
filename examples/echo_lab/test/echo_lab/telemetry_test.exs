defmodule EchoLab.TelemetryTest do
  use ExUnit.Case, async: true

  alias Supertester.Telemetry

  test "telemetry emit helpers" do
    handler_id = "echo-lab-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:supertester, :echo_lab, :custom],
          [:supertester, :concurrent, :scenario, :start],
          [:supertester, :concurrent, :scenario, :stop],
          [:supertester, :concurrent, :mailbox, :sample],
          [:supertester, :chaos, :start],
          [:supertester, :chaos, :stop],
          [:supertester, :performance, :scenario, :measured]
        ],
        &EchoLab.TelemetryTest.handle_telemetry/4,
        %{parent: parent}
      )

    Telemetry.emit([:echo_lab, :custom], %{value: 1}, %{tag: :ok})
    Telemetry.scenario_start(%{scenario_id: 1})
    Telemetry.scenario_stop(%{duration_ms: 5}, %{scenario_id: 1})
    Telemetry.mailbox_sample(%{max_size: 1}, %{scenario_id: 1})
    Telemetry.chaos_event(:start, %{value: 1}, %{scenario_id: 1})
    Telemetry.chaos_event(:stop, %{duration_ms: 2}, %{scenario_id: 1})
    Telemetry.performance_event(%{time_us: 5}, %{scenario_id: 1})

    assert_receive {:telemetry_event, [:supertester, :echo_lab, :custom], _, _}
    assert_receive {:telemetry_event, [:supertester, :concurrent, :scenario, :start], _, _}
    assert_receive {:telemetry_event, [:supertester, :concurrent, :scenario, :stop], _, _}
    assert_receive {:telemetry_event, [:supertester, :concurrent, :mailbox, :sample], _, _}
    assert_receive {:telemetry_event, [:supertester, :chaos, :start], _, _}
    assert_receive {:telemetry_event, [:supertester, :chaos, :stop], _, _}
    assert_receive {:telemetry_event, [:supertester, :performance, :scenario, :measured], _, _}

    :telemetry.detach(handler_id)
  end

  def handle_telemetry(event, measurements, metadata, config) do
    send(config.parent, {:telemetry_event, event, measurements, metadata})
  end
end
