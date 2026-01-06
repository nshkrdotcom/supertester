defmodule EchoLab.RootSupervisor do
  @moduledoc """
  Root supervisor with a nested supervisor and a counter.
  """

  use Supervisor

  alias EchoLab.{Counter, Names, OneForOneSupervisor}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    prefix = Keyword.get(opts, :name_prefix, "root")
    nested_name = Names.child_name(prefix, :nested_supervisor)

    children = [
      Supervisor.child_spec(
        {OneForOneSupervisor, name_prefix: "#{prefix}_nested", name: nested_name},
        id: :worker_supervisor
      ),
      Supervisor.child_spec({Counter, name: Names.child_name(prefix, :counter)}, id: :counter)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
