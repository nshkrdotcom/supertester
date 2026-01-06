defmodule EchoLab.OTPHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.OTPHelpers
  import Supertester.Assertions

  alias EchoLab.{Counter, OneForOneSupervisor}

  defmodule FailingServer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :fail, opts)
    end

    def init(_), do: {:stop, :bad_config}
  end

  defmodule FailingSupervisor do
    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, :ok, opts)
    end

    def init(_), do: {:stop, :bad_init}
  end

  test "setup_isolated_genserver tracks and cleans up" do
    {:ok, pid} = setup_isolated_genserver(Counter, "demo", init_args: [initial: 5])
    assert_process_alive(pid)
  end

  test "setup_isolated_genserver surfaces init errors" do
    assert {:error, {:start_failed, info}} = setup_isolated_genserver(FailingServer)
    assert info.module == FailingServer
    assert info.init_args == []
    assert info.reason == :bad_config
  end

  test "setup_isolated_supervisor surfaces init errors" do
    assert {:error, {:start_failed, info}} = setup_isolated_supervisor(FailingSupervisor)
    assert info.module == FailingSupervisor
    assert {:bad_return, _} = info.reason
  end

  test "wait_for_process_restart and supervisor restart helpers" do
    prefix = "otp_helpers_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        OneForOneSupervisor,
        "otp_helpers",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)

    [{:restart_worker, pid, _type, _mods} | _] = Supervisor.which_children(sup)
    refute is_nil(pid)

    Process.exit(pid, :kill)
    restart_name = EchoLab.Names.child_name(prefix, :restart_worker)
    assert {:ok, new_pid} = wait_for_process_restart(restart_name, pid, 2_000)
    assert is_pid(new_pid)
  end

  test "wait_for_supervisor_restart returns when children stabilize" do
    prefix = "otp_helpers_supervisor_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      setup_isolated_supervisor(
        OneForOneSupervisor,
        "otp_helpers_restart",
        init_args: [name_prefix: prefix]
      )

    Process.unlink(sup)

    assert {:ok, ^sup} = wait_for_supervisor_restart(sup, 1_000)
  end

  test "cleanup_on_exit registers callbacks" do
    {:ok, _pid} = EchoLab.TestEnv.start_link()
    original = Application.get_env(:supertester, :env_module)

    try do
      Application.put_env(:supertester, :env_module, EchoLab.TestEnv)

      {:ok, flag} = Agent.start(fn -> false end)
      cleanup_on_exit(fn -> Agent.update(flag, fn _ -> true end) end)

      EchoLab.TestEnv.run_callbacks()
      assert Agent.get(flag, & &1)
      Agent.stop(flag)
    after
      if original do
        Application.put_env(:supertester, :env_module, original)
      else
        Application.delete_env(:supertester, :env_module)
      end

      EchoLab.TestEnv.stop()
    end
  end

  test "wait_for_genserver_sync and wait_for_process_death" do
    {:ok, pid} = setup_isolated_genserver(Counter, "sync")
    assert :ok = wait_for_genserver_sync(pid, 500)

    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert {:ok, _} = wait_for_process_death(pid, 1_000)
  end

  test "monitor_process_lifecycle and cleanup_processes" do
    {:ok, pid} = setup_isolated_genserver(Counter, "monitor")
    {ref, ^pid} = monitor_process_lifecycle(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, pid2} = setup_isolated_genserver(Counter, "cleanup")
    :ok = cleanup_processes([pid2])
  end
end
