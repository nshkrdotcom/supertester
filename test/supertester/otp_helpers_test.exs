defmodule Supertester.OTPHelpersTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers

  defmodule NamedServer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(_args), do: {:ok, %{}}
  end

  defmodule FailingServer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :fail, opts)
    end

    def init(_args), do: {:stop, :bad_config}
  end

  defmodule SampleSupervisor do
    use Supervisor

    @impl true
    def init(_opts) do
      children = [
        %{
          id: __MODULE__.Worker,
          start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]}
        }
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule FailingSupervisor do
    use Supervisor

    @impl true
    def init(_opts), do: {:stop, :bad_init}
  end

  test "setup_isolated_genserver derives deterministic names and tracks processes", context do
    {:ok, pid} = setup_isolated_genserver(NamedServer, "named_worker")
    assert {:registered_name, name} = Process.info(pid, :registered_name)

    name_string = Atom.to_string(name)
    assert String.contains?(name_string, "NamedServer")
    assert String.contains?(name_string, "named_worker")

    sanitized_test_id =
      context.isolation_context.test_id
      |> Atom.to_string()
      |> String.replace(~r/[^a-zA-Z0-9]+/, "_")

    assert String.contains?(name_string, sanitized_test_id)

    isolation_context = Supertester.UnifiedTestFoundation.fetch_isolation_context()

    assert Enum.any?(isolation_context.processes, fn %{pid: tracked_pid} -> tracked_pid == pid end)
  end

  test "setup_isolated_genserver surfaces init errors with metadata" do
    assert {:error, {:start_failed, info}} = setup_isolated_genserver(FailingServer)
    assert info.module == FailingServer
    assert info.init_args == []
    assert info.reason == :bad_config
  end

  test "setup_isolated_supervisor propagates init errors with context" do
    assert {:error, {:start_failed, info}} = setup_isolated_supervisor(FailingSupervisor)
    assert info.module == FailingSupervisor
    assert {:bad_return, _} = info.reason
  end
end
