defmodule Supertester.Internal.SharedRegistryTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.SharedRegistry

  test "ensure_started/0 starts and reuses the shared registry" do
    assert {:ok, pid_1} = SharedRegistry.ensure_started()
    assert is_pid(pid_1)
    assert Process.alive?(pid_1)
    assert Process.whereis(SharedRegistry.name()) == pid_1

    assert {:ok, pid_2} = SharedRegistry.ensure_started()
    assert pid_1 == pid_2
  end
end
