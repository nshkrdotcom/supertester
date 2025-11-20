defmodule Supertester.Telemetry do
  @moduledoc """
  Centralized Telemetry instrumentation for Supertester.

  All public helpers eventually call `:telemetry.execute/3` with the `[:supertester | event]`
  prefix so consumers can subscribe to a consistent namespace.
  """

  @type measurements :: map()
  @type metadata :: map()

  @doc """
  Emits a raw telemetry event with the `[:supertester | event]` prefix.
  """
  @spec emit([atom()], measurements(), metadata()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}) when is_list(event) do
    :telemetry.execute([:supertester | event], measurements, metadata)
  catch
    _, _ -> :ok
  end

  @doc """
  Emits the scenario start event for the concurrent harness.
  """
  @spec scenario_start(metadata()) :: :ok
  def scenario_start(metadata \\ %{}) do
    emit(
      [:concurrent, :scenario, :start],
      %{system_time_us: System.system_time(:microsecond)},
      metadata
    )
  end

  @doc """
  Emits the scenario stop event for the concurrent harness.
  """
  @spec scenario_stop(measurements(), metadata()) :: :ok
  def scenario_stop(measurements \\ %{}, metadata \\ %{}) do
    emit([:concurrent, :scenario, :stop], measurements, metadata)
  end

  @doc """
  Emits mailbox sampling metrics captured during a scenario.
  """
  @spec mailbox_sample(measurements(), metadata()) :: :ok
  def mailbox_sample(measurements, metadata \\ %{}) when is_map(measurements) do
    emit([:concurrent, :mailbox, :sample], measurements, metadata)
  end

  @doc """
  Emits chaos lifecycle events.
  """
  @spec chaos_event(:start | :stop, measurements(), metadata()) :: :ok
  def chaos_event(type, measurements \\ %{}, metadata \\ %{}) do
    emit([:chaos, type], measurements, metadata)
  end

  @doc """
  Emits performance measurements produced for a scenario.
  """
  @spec performance_event(measurements(), metadata()) :: :ok
  def performance_event(measurements, metadata \\ %{}) do
    emit([:performance, :scenario, :measured], measurements, metadata)
  end
end
