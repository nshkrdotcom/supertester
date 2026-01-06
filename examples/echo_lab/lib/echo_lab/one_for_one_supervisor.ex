defmodule EchoLab.OneForOneSupervisor do
  @moduledoc """
  One-for-one supervisor with multiple named workers.
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
    prefix = Keyword.get(opts, :name_prefix, "one_for_one")
    max_restarts = Keyword.get(opts, :max_restarts, 3)
    max_seconds = Keyword.get(opts, :max_seconds, 5)

    children = [
      Supervisor.child_spec({Worker, name: Names.child_name(prefix, :worker_a)}, id: :worker_a),
      Supervisor.child_spec({Worker, name: Names.child_name(prefix, :worker_b)}, id: :worker_b),
      Supervisor.child_spec({Worker, name: Names.child_name(prefix, :restart_worker)},
        id: :restart_worker
      )
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    )
  end
end
