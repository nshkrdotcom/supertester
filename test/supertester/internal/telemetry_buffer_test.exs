defmodule Supertester.Internal.TelemetryBufferTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.TelemetryBuffer

  test "push/2 and drain/1 preserve event order" do
    {:ok, buffer} = TelemetryBuffer.start_link()

    assert :ok = TelemetryBuffer.push(buffer, :event_1)
    assert :ok = TelemetryBuffer.push(buffer, :event_2)
    assert [:event_1, :event_2] = TelemetryBuffer.drain(buffer)
    assert [] = TelemetryBuffer.drain(buffer)
  end

  test "stop/1 is idempotent for live and dead buffers" do
    {:ok, buffer} = TelemetryBuffer.start_link()
    assert :ok = TelemetryBuffer.stop(buffer)
    assert :ok = TelemetryBuffer.stop(buffer)
  end
end
