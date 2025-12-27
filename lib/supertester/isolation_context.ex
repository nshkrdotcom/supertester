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
          tags: map(),
          telemetry_test_id: integer() | nil,
          telemetry_handlers: [{String.t(), [[atom()]]}],
          logger_original_level: Logger.level() | nil,
          logger_isolated?: boolean(),
          isolated_ets_tables: %{atom() => :ets.tid() | atom()},
          ets_mirrors: [{atom(), :ets.tid() | atom()}],
          ets_injections: [{module(), atom(), term(), term()}]
        }

  @enforce_keys [:test_id]
  defstruct test_id: nil,
            registry: nil,
            processes: [],
            ets_tables: [],
            cleanup_callbacks: [],
            initial_processes: [],
            initial_ets_tables: [],
            tags: %{},
            telemetry_test_id: nil,
            telemetry_handlers: [],
            logger_original_level: nil,
            logger_isolated?: false,
            isolated_ets_tables: %{},
            ets_mirrors: [],
            ets_injections: []

  @doc "Get the isolated ETS table for a source table name."
  @spec get_ets_table(t(), atom()) :: :ets.tid() | atom() | nil
  def get_ets_table(%__MODULE__{isolated_ets_tables: tables}, source_name) do
    Map.get(tables, source_name)
  end

  @doc "Get the telemetry test ID for filtering."
  @spec telemetry_id(t()) :: integer() | nil
  def telemetry_id(%__MODULE__{telemetry_test_id: id}), do: id

  @doc "Check if logger isolation is active."
  @spec logger_isolated?(t()) :: boolean()
  def logger_isolated?(%__MODULE__{logger_isolated?: flag}), do: flag

  @doc "List all telemetry handler IDs."
  @spec telemetry_handlers(t()) :: [String.t()]
  def telemetry_handlers(%__MODULE__{telemetry_handlers: handlers}) do
    Enum.map(handlers, fn {id, _events} -> id end)
  end
end
