defmodule Supertester.Internal.ProcessWatch do
  @moduledoc false

  @spec await_down(reference(), pid(), timeout()) :: {:down, term()} | :timeout
  def await_down(ref, pid, timeout)
      when is_reference(ref) and is_pid(pid) and is_integer(timeout) and timeout >= 0 do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end
end
