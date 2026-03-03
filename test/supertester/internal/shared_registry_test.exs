defmodule Supertester.Internal.SharedRegistryTest do
  use ExUnit.Case, async: false

  alias Supertester.Internal.SharedRegistry

  setup do
    stop_registered_process(SharedRegistry.name())
    :ok
  end

  test "ensure_started/0 starts and reuses a ready shared registry" do
    assert {:ok, pid_1} = SharedRegistry.ensure_started()
    assert is_pid(pid_1)
    assert Process.alive?(pid_1)
    assert Process.whereis(SharedRegistry.name()) == pid_1
    assert :ets.whereis(SharedRegistry.name()) != :undefined

    assert {:ok, pid_2} = SharedRegistry.ensure_started()
    assert pid_1 == pid_2
  end

  test "ensure_started/0 replaces a stale named process with a real registry" do
    parent = self()

    fake =
      spawn(fn ->
        Process.register(self(), SharedRegistry.name())
        send(parent, {:fake_registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:fake_registered, ^fake}
    assert Process.whereis(SharedRegistry.name()) == fake
    ref = Process.monitor(fake)

    assert {:ok, registry_pid} = SharedRegistry.ensure_started()
    assert registry_pid != fake
    assert Process.alive?(registry_pid)
    assert Process.whereis(SharedRegistry.name()) == registry_pid
    assert :ets.whereis(SharedRegistry.name()) != :undefined
    assert_receive {:DOWN, ^ref, :process, ^fake, _reason}, 500
  end

  test "ensure_started/0 recovers after intentional registry reset" do
    assert {:ok, pid_1} = SharedRegistry.ensure_started()
    ref = Process.monitor(pid_1)
    Supervisor.stop(pid_1, :normal, 1_000)
    assert_receive {:DOWN, ^ref, :process, ^pid_1, reason}, 1_000
    assert reason in [:normal, :shutdown]

    assert {:ok, pid_2} = SharedRegistry.ensure_started()
    assert pid_2 != pid_1
    assert Process.alive?(pid_2)
    assert Process.whereis(SharedRegistry.name()) == pid_2
    assert :ets.whereis(SharedRegistry.name()) != :undefined
  end

  defp stop_registered_process(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)

        stop_reason =
          try do
            Supervisor.stop(pid, :normal, 1_000)
            :normal
          catch
            :exit, _ ->
              Process.exit(pid, :kill)
              :killed
          end

        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000

        if stop_reason == :normal do
          assert reason in [:normal, :shutdown]
        else
          assert reason == :killed
        end

        :ok

      _ ->
        :ok
    end
  end
end
