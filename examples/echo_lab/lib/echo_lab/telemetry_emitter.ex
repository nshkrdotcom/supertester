defmodule EchoLab.TelemetryEmitter do
  @moduledoc """
  Utility for emitting ad-hoc telemetry events in tests.
  """

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}) when is_list(event) do
    :telemetry.execute(event, measurements, metadata)
  end
end
