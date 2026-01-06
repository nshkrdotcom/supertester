defmodule EchoLab.ETSIsolationTest do
  use ExUnit.Case, async: true

  import Supertester.ETSIsolation

  alias EchoLab.TableStore

  test "setup_ets_isolation and create_isolated" do
    :ok = setup_ets_isolation()

    {:ok, table} = create_isolated(:set)
    assert :ets.info(table, :type) == :set
    assert {:error, :not_mirrored} = get_mirror(:missing)
  end

  test "setup_ets_isolation updates context and mirrors tables" do
    {:ok, context} =
      Supertester.UnifiedTestFoundation.setup_isolation(:full_isolation, %{test: :ets})

    {:ok, updated} = setup_ets_isolation(context.isolation_context)
    assert updated.isolated_ets_tables == %{}

    table_name = create_named_table(:echo_lab_source)
    :ets.insert(table_name, {:one, 1})

    {:ok, updated2} = setup_ets_isolation(updated, [table_name])
    assert Map.has_key?(updated2.isolated_ets_tables, table_name)

    :ets.delete(table_name)
  end

  test "mirror_table and get_mirror!" do
    :ok = setup_ets_isolation()
    table_name = create_named_table(:echo_lab_mirror)
    :ets.insert(table_name, {:two, 2})

    {:ok, mirror} = mirror_table(table_name, include_data: true)
    assert {:ok, ^mirror} = get_mirror(table_name)
    assert :ets.lookup(mirror, :two) == [{:two, 2}]
    assert get_mirror!(table_name) == mirror

    :ets.delete(table_name)
  end

  test "inject_table swaps table reference" do
    :ok = setup_ets_isolation()

    table_name = create_named_table(:echo_lab_table)
    TableStore.__supertester_set_table__(:table, table_name)
    TableStore.put(:alpha, 1)

    injected = String.to_atom("echo_lab_injected_#{System.unique_integer([:positive])}")
    {:ok, restore} = inject_table(TableStore, :table, injected)
    TableStore.put(:beta, 2)
    assert TableStore.count() == 1

    restore.()
    assert {:ok, 1} = TableStore.get(:alpha)

    :ets.delete(table_name)
    TableStore.clear_override()
  end

  test "with_table scopes ETS table" do
    :ok = setup_ets_isolation()

    result =
      with_table(:set, fn table ->
        :ets.insert(table, {:key, :value})
        :ets.lookup(table, :key)
      end)

    assert result == [{:key, :value}]

    result2 =
      with_table(:set, [:public], fn table ->
        :ets.insert(table, {:key2, :value2})
        :ets.lookup(table, :key2)
      end)

    assert result2 == [{:key2, :value2}]
  end

  defp create_named_table(base) do
    name = String.to_atom("#{base}_#{System.unique_integer([:positive])}")
    :ets.new(name, [:named_table, :public, :set])
  end
end
