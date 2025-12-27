defmodule Supertester.ETSIsolationTest do
  use ExUnit.Case, async: true

  alias Supertester.{ETSIsolation, IsolationContext}

  defmodule InjectedTableModule do
    @default_table :supertester_default_table

    def table_name do
      Process.get({__MODULE__, :table_override}, @default_table)
    end

    def __supertester_set_table__(:table_name, table_ref) do
      if table_ref == @default_table do
        Process.delete({__MODULE__, :table_override})
      else
        Process.put({__MODULE__, :table_override}, table_ref)
      end

      :ok
    end
  end

  defp unique_table_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp safe_delete_table(table_name) do
    case :ets.info(table_name) do
      :undefined -> :ok
      _info -> :ets.delete(table_name)
    end
  end

  describe "setup_ets_isolation/0" do
    test "initializes ETS isolation state" do
      assert :ok = ETSIsolation.setup_ets_isolation()
      assert Process.get(:supertester_ets_isolated) == true
    end
  end

  describe "setup_ets_isolation/1 with tables" do
    test "auto-mirrors the provided tables" do
      table_name = unique_table_name("source_table")
      :ets.new(table_name, [:set, :public, :named_table])
      on_exit(fn -> safe_delete_table(table_name) end)

      assert :ok = ETSIsolation.setup_ets_isolation([table_name])
      assert {:ok, mirror} = ETSIsolation.get_mirror(table_name)
      assert :ets.info(mirror) != :undefined
    end
  end

  describe "setup_ets_isolation/1 with context" do
    test "updates the isolation context" do
      ctx = %IsolationContext{test_id: :ets_test}

      {:ok, updated_ctx} = ETSIsolation.setup_ets_isolation(ctx)

      assert updated_ctx.isolated_ets_tables == %{}
      assert updated_ctx.ets_mirrors == []
      assert updated_ctx.ets_injections == []
    end
  end

  describe "setup_ets_isolation/2 with context and tables" do
    test "updates context with mirrored tables" do
      table_name = unique_table_name("context_table")
      :ets.new(table_name, [:set, :public, :named_table])
      on_exit(fn -> safe_delete_table(table_name) end)

      ctx = %IsolationContext{test_id: :ets_context_test}

      {:ok, updated_ctx} = ETSIsolation.setup_ets_isolation(ctx, [table_name])

      assert %{^table_name => mirror} = updated_ctx.isolated_ets_tables

      assert Enum.any?(updated_ctx.ets_mirrors, fn {source, mirror_ref} ->
               source == table_name and mirror_ref == mirror
             end)
    end
  end

  describe "table creation and mirroring" do
    setup do
      ETSIsolation.setup_ets_isolation()
      :ok
    end

    test "create_isolated/1 builds an unnamed table" do
      {:ok, table} = ETSIsolation.create_isolated(:set)

      :ets.insert(table, {:key, :value})
      assert :ets.lookup(table, :key) == [{:key, :value}]
      assert :ets.info(table) != :undefined
    end

    test "create_isolated/2 supports named tables" do
      name = unique_table_name("named")
      {:ok, table} = ETSIsolation.create_isolated(:set, name: name)

      assert table == name
      assert :ets.info(name) != :undefined
    end

    test "mirror_table/1 creates an empty mirror" do
      source = unique_table_name("mirror_source")
      :ets.new(source, [:set, :public, :named_table])
      :ets.insert(source, {:a, 1})
      on_exit(fn -> safe_delete_table(source) end)

      {:ok, mirror} = ETSIsolation.mirror_table(source)

      assert :ets.info(mirror, :size) == 0
    end

    test "mirror_table/2 copies data when requested" do
      source = unique_table_name("mirror_source_data")
      :ets.new(source, [:set, :public, :named_table])
      :ets.insert(source, {:a, 1})
      on_exit(fn -> safe_delete_table(source) end)

      {:ok, mirror} = ETSIsolation.mirror_table(source, include_data: true)

      assert :ets.lookup(mirror, :a) == [{:a, 1}]
    end
  end

  describe "mirror accessors" do
    setup do
      ETSIsolation.setup_ets_isolation()
      :ok
    end

    test "get_mirror/1 returns mirrors for known tables" do
      source = unique_table_name("mirror_lookup")
      :ets.new(source, [:set, :public, :named_table])
      on_exit(fn -> safe_delete_table(source) end)

      {:ok, mirror} = ETSIsolation.mirror_table(source)
      assert {:ok, ^mirror} = ETSIsolation.get_mirror(source)
    end

    test "get_mirror!/1 raises when missing" do
      assert {:error, :not_mirrored} = ETSIsolation.get_mirror(:missing_table)

      assert_raise ArgumentError, fn ->
        ETSIsolation.get_mirror!(:missing_table)
      end
    end
  end

  describe "table injection" do
    setup do
      ETSIsolation.setup_ets_isolation()
      :ok
    end

    test "inject_table/3 swaps the table reference" do
      replacement = unique_table_name("replacement")

      {:ok, restore} =
        ETSIsolation.inject_table(InjectedTableModule, :table_name, replacement,
          table_opts: [:set, :public, :named_table]
        )

      assert InjectedTableModule.table_name() == replacement

      :ok = restore.()
      assert InjectedTableModule.table_name() == :supertester_default_table
      assert :ets.info(replacement) == :undefined
    end

    test "inject_table/4 supports using an existing table" do
      table = :ets.new(unique_table_name("existing"), [:set, :public])

      {:ok, restore} =
        ETSIsolation.inject_table(InjectedTableModule, :table_name, table,
          create: false,
          cleanup: false
        )

      assert InjectedTableModule.table_name() == table

      :ok = restore.()
      assert InjectedTableModule.table_name() == :supertester_default_table
      assert :ets.info(table) != :undefined
      :ets.delete(table)
    end
  end

  describe "with_table/2 and with_table/3" do
    setup do
      ETSIsolation.setup_ets_isolation()
      :ok
    end

    test "with_table/2 deletes the table after scope" do
      table_ref =
        ETSIsolation.with_table(:set, fn table ->
          :ets.insert(table, {:key, :value})
          table
        end)

      assert :ets.info(table_ref) == :undefined
    end

    test "with_table/3 returns the function result" do
      result =
        ETSIsolation.with_table(:set, [:public], fn table ->
          :ets.insert(table, {:key, :value})
          :ets.lookup(table, :key)
        end)

      assert result == [{:key, :value}]
    end
  end
end
