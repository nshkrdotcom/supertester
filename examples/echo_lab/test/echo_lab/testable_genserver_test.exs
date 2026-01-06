defmodule EchoLab.TestableGenServerTest do
  use ExUnit.Case, async: true

  alias EchoLab.TestableCounter

  test "sync handler responds and can return state" do
    {:ok, pid} = TestableCounter.start_link(initial: 3)

    assert :ok = GenServer.call(pid, :__supertester_sync__)
    assert {:ok, %{count: 3}} = GenServer.call(pid, {:__supertester_sync__, return_state: true})
  end
end
