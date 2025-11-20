defmodule Supertester.MessageHarness do
  @moduledoc """
  Utilities for observing messages delivered to a process during a function run.

  These helpers are intended for troubleshooting concurrent tests where mailbox
  visibility is important. They integrate with `ConcurrentHarness` reports but
  can also be used standalone.
  """

  @doc """
  Traces messages received by `pid` while executing `fun`.

  Returns a map with the traced messages in arrival order, along with the
  original mailbox snapshots and the wrapped function result.
  """
  @spec trace_messages(pid(), (-> any()), keyword()) :: %{
          messages: [term()],
          result: term(),
          initial_mailbox: [term()],
          final_mailbox: [term()]
        }
  def trace_messages(pid, fun, opts \\ []) when is_pid(pid) and is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    {:messages, initial_mailbox} = Process.info(pid, :messages)

    collector =
      Task.async(fn ->
        collect_trace_messages([])
      end)

    :erlang.trace(pid, true, [:receive, {:tracer, collector.pid}])

    result =
      try do
        fun.()
      after
        :erlang.trace(pid, false, [:receive])
        send(collector.pid, :stop)
      end

    messages =
      collector
      |> Task.await(timeout)
      |> Enum.reverse()

    {:messages, final_mailbox} = Process.info(pid, :messages)

    %{
      messages: messages,
      result: result,
      initial_mailbox: initial_mailbox,
      final_mailbox: final_mailbox
    }
  end

  defp collect_trace_messages(acc) do
    receive do
      {:trace, _pid, :receive, message} ->
        collect_trace_messages([message | acc])

      :stop ->
        acc
    end
  end
end
