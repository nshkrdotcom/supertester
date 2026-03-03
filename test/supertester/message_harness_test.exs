defmodule Supertester.MessageHarnessTest do
  use ExUnit.Case, async: true

  alias Supertester.MessageHarness

  defmodule Target do
    def start_link do
      Task.start_link(fn -> loop() end)
    end

    defp loop do
      receive do
        {:stop, caller} ->
          send(caller, :stopped)

        {:ack, caller} ->
          send(caller, :ack)
          loop()

        _ ->
          loop()
      end
    end
  end

  test "trace_messages captures delivered messages" do
    {:ok, pid} = Target.start_link()

    report =
      MessageHarness.trace_messages(pid, fn ->
        send(pid, {:direct, :hello})
        # Synchronize: send ack request and wait for response
        # This proves Target received our earlier message (FIFO ordering)
        send(pid, {:ack, self()})
        receive do: (:ack -> :ok)
      end)

    assert {:direct, :hello} in report.messages
    assert report.result == :ok

    send(pid, {:stop, self()})
    assert_receive :stopped
  end

  test "trace_messages raises a descriptive error on collector timeout" do
    {:ok, pid} = Target.start_link()

    assert_raise RuntimeError, ~r/timed out collecting traced messages/i, fn ->
      MessageHarness.trace_messages(
        pid,
        fn ->
          for _ <- 1..50_000 do
            send(pid, :noise)
          end
        end,
        timeout: 0
      )
    end

    send(pid, {:stop, self()})
    assert_receive :stopped
  end
end
