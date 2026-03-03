defmodule Supertester.Internal.ProcessRefTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.ProcessRef

  defmodule ViaRegistry do
    def whereis_name(_), do: :undefined
  end

  test "resolve/1 returns pids directly" do
    pid = self()
    assert ProcessRef.resolve(pid) == pid
  end

  test "resolve/1 handles local atom names" do
    name = :"process_ref_local_#{System.unique_integer([:positive])}"
    pid = spawn(fn -> wait_forever() end)
    Process.register(pid, name)

    assert ProcessRef.resolve(name) == pid
    Process.exit(pid, :kill)
  end

  test "resolve/1 handles global names" do
    name = {:process_ref_global, self(), System.unique_integer([:positive])}
    pid = spawn(fn -> wait_forever() end)
    :yes = :global.register_name(name, pid)

    assert ProcessRef.resolve({:global, name}) == pid

    :global.unregister_name(name)
    Process.exit(pid, :kill)
  end

  test "resolve/1 handles via names and undefined values" do
    assert ProcessRef.resolve({:via, ViaRegistry, :missing}) == nil
    assert ProcessRef.resolve(:definitely_not_registered) == nil
    assert ProcessRef.resolve({:global, :missing}) == nil
    assert ProcessRef.resolve("invalid") == nil
  end

  test "alive?/1 resolves references and checks liveness" do
    pid = spawn(fn -> wait_forever() end)
    name = :"process_ref_alive_#{System.unique_integer([:positive])}"
    Process.register(pid, name)

    assert ProcessRef.alive?(name)
    Process.exit(pid, :kill)
    refute ProcessRef.alive?(name)
  end

  defp wait_forever do
    receive do
      :stop -> :ok
    end
  end
end
