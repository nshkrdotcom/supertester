defmodule EchoLab.OneForAllSupervisor do
  @moduledoc """
  One-for-all supervisor used for restart strategy tests.
  """

  use Supervisor

  alias EchoLab.Names
  alias EchoLab.Worker

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    prefix = Keyword.get(opts, :name_prefix, "one_for_all")

    children = [
      Supervisor.child_spec({Worker, name: Names.child_name(prefix, :alpha)}, id: :alpha),
      Supervisor.child_spec({Worker, name: Names.child_name(prefix, :beta)}, id: :beta)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
