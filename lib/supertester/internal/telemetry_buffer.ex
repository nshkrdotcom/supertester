defmodule Supertester.Internal.TelemetryBuffer do
  @moduledoc false

  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link do
    Agent.start_link(fn -> [] end)
  end

  @spec push(pid(), term()) :: :ok | {:error, :buffer_unavailable}
  def push(buffer_pid, message) when is_pid(buffer_pid) do
    Agent.update(buffer_pid, &[message | &1])
    :ok
  catch
    :exit, _ -> {:error, :buffer_unavailable}
  end

  @spec drain(pid()) :: [term()]
  def drain(buffer_pid) when is_pid(buffer_pid) do
    Agent.get_and_update(buffer_pid, fn messages ->
      {Enum.reverse(messages), []}
    end)
  catch
    :exit, _ -> []
  end

  @spec stop(pid()) :: :ok
  def stop(buffer_pid) when is_pid(buffer_pid) do
    if Process.alive?(buffer_pid) do
      try do
        Agent.stop(buffer_pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
