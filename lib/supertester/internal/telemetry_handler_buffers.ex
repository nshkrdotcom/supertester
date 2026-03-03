defmodule Supertester.Internal.TelemetryHandlerBuffers do
  @moduledoc false

  @spec track(atom(), String.t(), pid() | nil) :: :ok
  def track(_key, _handler_id, nil), do: :ok

  def track(key, handler_id, buffer_pid) when is_pid(buffer_pid) do
    buffers = Process.get(key, %{})
    Process.put(key, Map.put(buffers, handler_id, buffer_pid))
    :ok
  end

  @spec fetch(atom(), String.t()) :: pid() | nil
  def fetch(key, handler_id) do
    Process.get(key, %{})
    |> Map.get(handler_id)
  end

  @spec pop(atom(), String.t()) :: pid() | nil
  def pop(key, handler_id) do
    buffers = Process.get(key, %{})
    {buffer_pid, remaining} = Map.pop(buffers, handler_id)
    Process.put(key, remaining)
    buffer_pid
  end
end
