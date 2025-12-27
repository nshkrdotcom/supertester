defmodule Supertester.ETSIsolation do
  @moduledoc """
  Per-test ETS table management for async-safe isolation.
  """

  alias Supertester.{Env, IsolationContext, Telemetry, UnifiedTestFoundation}

  @type table_type :: :set | :ordered_set | :bag | :duplicate_bag
  @type table_access :: :public | :protected | :private
  @type table_option ::
          table_type()
          | table_access()
          | :named_table
          | {:keypos, pos_integer()}
          | {:heir, pid(), term()}
          | {:write_concurrency, boolean()}
          | {:read_concurrency, boolean()}
          | :compressed

  @type table_ref :: :ets.tid() | atom()
  @type table_name :: atom()

  @type create_opts :: [
          name: atom(),
          copy_from: table_ref(),
          owner: pid(),
          cleanup: boolean()
        ]

  @type mirror_opts :: [
          include_data: boolean(),
          access: table_access(),
          cleanup: boolean()
        ]

  @type inject_opts :: [
          create: boolean(),
          table_opts: [table_option()],
          cleanup: boolean()
        ]

  @ets_isolated_key :supertester_ets_isolated
  @ets_tables_key :supertester_ets_tables
  @ets_mirrors_key :supertester_ets_mirrors
  @ets_injections_key :supertester_ets_injections

  @doc """
  Initialize ETS isolation for the current process.
  """
  @spec setup_ets_isolation() :: :ok
  def setup_ets_isolation do
    Process.put(@ets_isolated_key, true)
    Process.put(@ets_tables_key, [])
    Process.put(@ets_mirrors_key, %{})
    Process.put(@ets_injections_key, [])

    Env.on_exit(fn ->
      cleanup_all_tables()
    end)

    maybe_update_context(fn ctx ->
      %{ctx | isolated_ets_tables: %{}, ets_mirrors: [], ets_injections: []}
    end)

    emit_setup()
    :ok
  end

  @doc """
  Initialize ETS isolation and optionally auto-mirror tables or update context.
  """
  @spec setup_ets_isolation([table_name()]) :: :ok
  def setup_ets_isolation(tables) when is_list(tables) do
    :ok = setup_ets_isolation()

    Enum.each(tables, fn table_name ->
      {:ok, _mirror} = mirror_table(table_name)
    end)

    :ok
  end

  @spec setup_ets_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}
  def setup_ets_isolation(%IsolationContext{} = ctx) do
    :ok = setup_ets_isolation()

    updated_ctx = %{ctx | isolated_ets_tables: %{}, ets_mirrors: [], ets_injections: []}
    UnifiedTestFoundation.put_isolation_context(updated_ctx)
    {:ok, updated_ctx}
  end

  @doc """
  Initialize ETS isolation, auto-mirror tables, and update context.
  """
  @spec setup_ets_isolation(IsolationContext.t(), [table_name()]) ::
          {:ok, IsolationContext.t()}
  def setup_ets_isolation(%IsolationContext{} = ctx, tables) when is_list(tables) do
    {:ok, ctx} = setup_ets_isolation(ctx)

    Enum.each(tables, fn table_name ->
      {:ok, _mirror} = mirror_table(table_name)
    end)

    updated_ctx = UnifiedTestFoundation.fetch_isolation_context() || ctx
    {:ok, updated_ctx}
  end

  @doc """
  Create an isolated ETS table with automatic cleanup.
  """
  @spec create_isolated(table_type()) :: {:ok, table_ref()}
  @spec create_isolated(table_type(), [table_option() | create_opts()]) :: {:ok, table_ref()}
  def create_isolated(type, opts \\ []) do
    ensure_isolation_setup!()

    {create_opts, ets_opts} = split_create_opts(opts)
    ets_opts = [type | ets_opts]

    table =
      case Keyword.get(create_opts, :name) do
        nil ->
          :ets.new(:supertester_isolated_table, ets_opts)

        name ->
          :ets.new(name, [:named_table | ets_opts])
      end

    if source = Keyword.get(create_opts, :copy_from) do
      copy_table_data(source, table)
    end

    if owner = Keyword.get(create_opts, :owner) do
      :ets.give_away(table, owner, :supertester_transfer)
    end

    if Keyword.get(create_opts, :cleanup, true) do
      register_table_for_cleanup(table)
    end

    emit_created(table, type)
    {:ok, table}
  end

  @doc """
  Create an isolated copy of an existing named table.
  """
  @spec mirror_table(table_name()) ::
          {:ok, table_ref()} | {:error, {:table_not_found, table_name()}}
  @spec mirror_table(table_name(), mirror_opts()) ::
          {:ok, table_ref()} | {:error, {:table_not_found, table_name()}}
  def mirror_table(source_name, opts \\ []) do
    ensure_isolation_setup!()

    include_data = Keyword.get(opts, :include_data, false)
    access = Keyword.get(opts, :access, :public)
    cleanup = Keyword.get(opts, :cleanup, true)

    source_info = :ets.info(source_name)

    if source_info == :undefined do
      {:error, {:table_not_found, source_name}}
    else
      type = Keyword.get(source_info, :type)
      keypos = Keyword.get(source_info, :keypos)

      mirror_opts = [type, access, {:keypos, keypos}]
      mirror = :ets.new(:supertester_mirror, mirror_opts)

      if include_data do
        copy_table_data(source_name, mirror)
      end

      register_mirror(source_name, mirror)

      if cleanup do
        register_table_for_cleanup(mirror)
      end

      emit_mirrored(source_name, mirror, :ets.info(mirror, :size))
      {:ok, mirror}
    end
  end

  @doc """
  Temporarily replace a module's table reference.
  """
  @spec inject_table(module(), atom(), table_name() | table_ref()) :: {:ok, (-> :ok)}
  @spec inject_table(module(), atom(), table_name() | table_ref(), inject_opts()) ::
          {:ok, (-> :ok)}
  def inject_table(module, function_or_attribute, replacement, opts \\ []) do
    ensure_isolation_setup!()

    create = Keyword.get(opts, :create, true)
    table_opts = Keyword.get(opts, :table_opts, [:set, :public, :named_table])
    cleanup = Keyword.get(opts, :cleanup, true)

    replacement_table =
      if create and is_atom(replacement) do
        :ets.new(replacement, table_opts)
      else
        replacement
      end

    original = get_module_table_ref(module, function_or_attribute)
    injection = {module, function_or_attribute, original, replacement_table}
    register_injection(injection)

    set_module_table_ref(module, function_or_attribute, replacement_table)

    restore_fn = fn ->
      set_module_table_ref(module, function_or_attribute, original)

      if create do
        safe_delete_table(replacement_table)
      end

      :ok
    end

    if cleanup do
      Env.on_exit(restore_fn)
    end

    emit_injected(module, function_or_attribute, replacement_table)
    {:ok, restore_fn}
  end

  @doc """
  Execute a function with a temporary ETS table that is deleted after scope.
  """
  @dialyzer {:nowarn_function, with_table: 2}
  @spec with_table(table_type(), (table_ref() -> term())) :: term()
  @dialyzer {:nowarn_function, with_table: 3}
  @spec with_table(table_type(), [table_option()], (table_ref() -> term())) :: term()
  def with_table(type, fun) when is_function(fun, 1) do
    with_table(type, [], fun)
  end

  def with_table(type, opts, fun) when is_list(opts) and is_function(fun, 1) do
    {:ok, table} = create_isolated(type, opts ++ [cleanup: false])

    try do
      fun.(table)
    after
      safe_delete_table(table)
    end
  end

  @doc """
  Get the mirror table for a source table.
  """
  @spec get_mirror(table_name()) :: {:ok, table_ref()} | {:error, :not_mirrored}
  def get_mirror(source_name) do
    mirrors = Process.get(@ets_mirrors_key, %{})

    case Map.get(mirrors, source_name) do
      nil -> {:error, :not_mirrored}
      mirror -> {:ok, mirror}
    end
  end

  @doc """
  Get the mirror table or raise if not found.
  """
  @spec get_mirror!(table_name()) :: table_ref()
  def get_mirror!(source_name) do
    case get_mirror(source_name) do
      {:ok, mirror} ->
        mirror

      {:error, :not_mirrored} ->
        raise ArgumentError, "No mirror exists for table #{inspect(source_name)}"
    end
  end

  @spec ensure_isolation_setup!() :: :ok
  defp ensure_isolation_setup! do
    case Process.get(@ets_isolated_key, false) do
      true -> :ok
      _ -> raise "ETS isolation not set up. Call setup_ets_isolation/0 first."
    end
  end

  defp split_create_opts(opts) do
    Enum.reduce(opts, {[], []}, fn
      {key, _value} = option, {create_opts, ets_opts}
      when key in [:name, :copy_from, :owner, :cleanup] ->
        {[option | create_opts], ets_opts}

      {_key, _value} = option, {create_opts, ets_opts} ->
        {create_opts, [option | ets_opts]}

      option, {create_opts, ets_opts} ->
        {create_opts, [option | ets_opts]}
    end)
    |> then(fn {create_opts, ets_opts} ->
      {Enum.reverse(create_opts), Enum.reverse(ets_opts)}
    end)
  end

  defp register_table_for_cleanup(table) do
    tables = Process.get(@ets_tables_key, [])
    Process.put(@ets_tables_key, [table | tables])

    maybe_update_context(fn ctx ->
      UnifiedTestFoundation.add_tracked_ets_table(ctx, table)
    end)
  end

  defp register_mirror(source_name, mirror) do
    mirrors = Process.get(@ets_mirrors_key, %{})
    Process.put(@ets_mirrors_key, Map.put(mirrors, source_name, mirror))

    maybe_update_context(fn ctx ->
      %{
        ctx
        | isolated_ets_tables: Map.put(ctx.isolated_ets_tables, source_name, mirror),
          ets_mirrors: [{source_name, mirror} | ctx.ets_mirrors]
      }
    end)
  end

  defp register_injection(injection) do
    injections = Process.get(@ets_injections_key, [])
    Process.put(@ets_injections_key, [injection | injections])

    maybe_update_context(fn ctx ->
      %{ctx | ets_injections: [injection | ctx.ets_injections]}
    end)
  end

  defp cleanup_all_tables do
    tables = Process.get(@ets_tables_key, [])
    deleted_count = count_deleted_tables(tables)

    injections = Process.get(@ets_injections_key, [])
    deleted_injections = cleanup_injections(injections)

    Process.delete(@ets_isolated_key)
    Process.delete(@ets_tables_key)
    Process.delete(@ets_mirrors_key)
    Process.delete(@ets_injections_key)

    emit_cleanup_complete(deleted_count + deleted_injections)
    :ok
  end

  defp cleanup_injections(injections) do
    Enum.reduce(injections, 0, fn {module, attr, original, replacement}, acc ->
      set_module_table_ref(module, attr, original)
      acc + if(safe_delete_table(replacement), do: 1, else: 0)
    end)
  end

  defp count_deleted_tables(tables) do
    Enum.reduce(tables, 0, fn table, acc ->
      acc + if(safe_delete_table(table), do: 1, else: 0)
    end)
  end

  defp safe_delete_table(table) do
    :ets.delete(table)
    emit_deleted(table)
    true
  rescue
    ArgumentError -> false
  catch
    :error, :badarg -> false
  end

  defp copy_table_data(source, dest) do
    :ets.foldl(
      fn row, _ ->
        :ets.insert(dest, row)
      end,
      :ok,
      source
    )
  end

  defp get_module_table_ref(module, function_name) when is_atom(function_name) do
    apply(module, function_name, [])
  end

  defp set_module_table_ref(module, function_name, table) when is_atom(function_name) do
    if function_exported?(module, :__supertester_set_table__, 2) do
      module.__supertester_set_table__(function_name, table)
    else
      app = Application.get_application(module)
      key = :"#{module}_#{function_name}"
      Application.put_env(app, key, table)
    end
  end

  defp maybe_update_context(fun) do
    case UnifiedTestFoundation.fetch_isolation_context() do
      %IsolationContext{} = ctx ->
        updated_ctx = fun.(ctx)
        UnifiedTestFoundation.put_isolation_context(updated_ctx)
        updated_ctx

      _ ->
        nil
    end
  end

  defp emit_setup do
    Telemetry.emit([:ets, :isolation, :setup], %{}, %{pid: self()})
  end

  defp emit_created(table, type) do
    Telemetry.emit([:ets, :table, :created], %{}, %{table: table, type: type})
  end

  defp emit_mirrored(source, mirror, row_count) do
    Telemetry.emit([:ets, :table, :mirrored], %{row_count: row_count}, %{
      source: source,
      mirror: mirror
    })
  end

  defp emit_injected(module, attribute, table) do
    Telemetry.emit([:ets, :table, :injected], %{}, %{
      module: module,
      attribute: attribute,
      table: table
    })
  end

  defp emit_deleted(table) do
    Telemetry.emit([:ets, :table, :deleted], %{}, %{table: table})
  end

  defp emit_cleanup_complete(count) do
    Telemetry.emit([:ets, :cleanup, :complete], %{tables_deleted: count}, %{pid: self()})
  end
end
