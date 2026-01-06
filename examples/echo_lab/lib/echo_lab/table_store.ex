defmodule EchoLab.TableStore do
  @moduledoc """
  Simple ETS-backed store with a swappable table reference.
  """

  @table_key {__MODULE__, :table}

  @spec table() :: :ets.tid() | atom()
  def table do
    :persistent_term.get(@table_key, :echo_lab_table)
  end

  @spec __supertester_set_table__(atom(), :ets.tid() | atom()) :: :ok
  def __supertester_set_table__(:table, table) do
    :persistent_term.put(@table_key, table)
    :ok
  end

  @spec clear_override() :: :ok
  def clear_override do
    :persistent_term.erase(@table_key)
    :ok
  end

  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(table(), {key, value})
    :ok
  end

  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(table(), :size) do
      :undefined -> 0
      size -> size
    end
  end
end
