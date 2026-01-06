defmodule EchoLab.MessageHarnessTest do
  use ExUnit.Case, async: true

  alias Supertester.MessageHarness

  test "trace_messages captures delivered messages" do
    parent = self()

    pid =
      spawn(fn ->
        receive_messages(parent)
      end)

    report =
      MessageHarness.trace_messages(pid, fn ->
        send(pid, {:hello, 1})
        assert_receive {:received, {:hello, 1}}
        send(pid, {:hello, 2})
        assert_receive {:received, {:hello, 2}}
        :ok
      end)

    assert {:hello, 1} in report.messages
    assert {:hello, 2} in report.messages

    send(pid, :stop)
  end

  defp receive_messages(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {:received, message})
        receive_messages(parent)
    end
  end
end
