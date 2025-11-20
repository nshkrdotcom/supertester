defmodule Supertester.IsolationContext do
  @moduledoc """
  Normalized representation of all resources and metadata tracked for a test.
  """

  @type process_info :: %{pid: pid(), name: atom() | nil, module: module()}

  @type t :: %__MODULE__{
          test_id: term(),
          registry: atom() | nil,
          processes: [process_info()],
          ets_tables: [term()],
          cleanup_callbacks: [(-> any())],
          initial_processes: [pid()],
          initial_ets_tables: [term()],
          tags: map()
        }

  @enforce_keys [:test_id]
  defstruct test_id: nil,
            registry: nil,
            processes: [],
            ets_tables: [],
            cleanup_callbacks: [],
            initial_processes: [],
            initial_ets_tables: [],
            tags: %{}
end
