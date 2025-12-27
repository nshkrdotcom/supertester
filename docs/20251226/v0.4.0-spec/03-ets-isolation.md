# Supertester.ETSIsolation Specification

## Module Purpose

Provide per-test ETS table management that eliminates state leakage between concurrent tests, including table mirroring, scoped access, and application-level table injection.

---

## The Problem in Detail

### Named ETS Tables are Global

Named ETS tables are shared across all processes in the VM. When tests run concurrently and access the same named table, they corrupt each other's state:

```elixir
# Application code uses a named cache table
defmodule MyApp.Cache do
  def get(key), do: :ets.lookup(:myapp_cache, key)
  def put(key, value), do: :ets.insert(:myapp_cache, {key, value})
  def clear(), do: :ets.delete_all_objects(:myapp_cache)
end

# Test A
setup do
  MyApp.Cache.clear()  # Nukes Test B's data!
  :ok
end

test "caches values" do
  MyApp.Cache.put(:key, :value_a)
  assert MyApp.Cache.get(:key) == [{:key, :value_a}]  # FLAKY!
end

# Test B (concurrent)
test "caches other values" do
  MyApp.Cache.put(:key, :value_b)
  # Test A's clear() just ran, or will run, corrupting this test
  assert MyApp.Cache.get(:key) == [{:key, :value_b}]  # FLAKY!
end
```

### Common Anti-Patterns

**Anti-Pattern 1: Clearing tables in setup**
```elixir
setup do
  :ets.delete_all_objects(:shared_table)  # Affects concurrent tests
  :ok
end
```

**Anti-Pattern 2: Using async: false**
```elixir
use ExUnit.Case, async: false  # Works but slow
```

**Anti-Pattern 3: Creating table per test without cleanup**
```elixir
setup do
  table = :ets.new(:test_table, [:set, :public])
  on_exit(fn -> :ets.delete(table) end)  # Forget this once = resource leak
  {:ok, table: table}
end
```

**Anti-Pattern 4: Hardcoded table names in application code**
```elixir
# Can't inject different table for tests
def cache_table, do: :myapp_cache
```

---

## Solution: Multi-Strategy ETS Isolation

### Strategy 1: Create Isolated Tables

Create unnamed or uniquely-named tables per test:

```elixir
setup do
  {:ok, table} = ETSIsolation.create_isolated(:set, [:public])
  {:ok, table: table}
end

test "uses isolated table", %{table: table} do
  :ets.insert(table, {:key, :value})
  assert :ets.lookup(table, :key) == [{:key, :value}]
end
```

### Strategy 2: Mirror Existing Tables

Create a copy of an existing named table for isolated access:

```elixir
setup do
  {:ok, mirror} = ETSIsolation.mirror_table(:myapp_cache)
  {:ok, cache: mirror}
end

test "uses mirrored table", %{cache: cache} do
  :ets.insert(cache, {:key, :value})
  # Original :myapp_cache is untouched
end
```

### Strategy 3: Inject Table References

Temporarily replace a module's table reference:

```elixir
setup do
  {:ok, _restore_fn} = ETSIsolation.inject_table(MyApp.Cache, :table_name, :test_cache)
  {:ok, []}
end

test "uses injected table" do
  MyApp.Cache.put(:key, :value)
  # Uses :test_cache instead of :myapp_cache
end
```

### Strategy 4: Scoped Table Access

Use a table only within a specific scope:

```elixir
test "scoped table usage" do
  result = ETSIsolation.with_table(:set, [:public], fn table ->
    :ets.insert(table, {:key, :value})
    :ets.lookup(table, :key)
  end)

  assert result == [{:key, :value}]
  # Table automatically deleted after scope
end
```

---

## API Specification

### Types

```elixir
@type table_type :: :set | :ordered_set | :bag | :duplicate_bag
@type table_access :: :public | :protected | :private
@type table_option ::
  table_type() |
  table_access() |
  :named_table |
  {:keypos, pos_integer()} |
  {:heir, pid(), term()} |
  {:write_concurrency, boolean()} |
  {:read_concurrency, boolean()} |
  :compressed

@type table_ref :: :ets.tid() | atom()
@type table_name :: atom()

@type create_opts :: [
  name: atom(),           # Optional name (creates named_table)
  copy_from: table_ref(), # Copy data from existing table
  owner: pid(),           # Table owner (default: test process)
  cleanup: boolean()      # Register automatic cleanup (default: true)
]

@type mirror_opts :: [
  include_data: boolean(),  # Copy existing data (default: false)
  access: table_access(),   # Access level for mirror (default: :public)
  cleanup: boolean()        # Register automatic cleanup (default: true)
]

@type inject_opts :: [
  create: boolean(),      # Create the replacement table (default: true)
  table_opts: [table_option()],  # Options for created table
  cleanup: boolean()      # Restore original on cleanup (default: true)
]
```

### Core Functions

#### `setup_ets_isolation/0`

Initialize ETS isolation for the current test. Called automatically by ExUnitFoundation when `ets_isolation` is configured.

```elixir
@spec setup_ets_isolation() :: :ok
@spec setup_ets_isolation([table_name()]) :: :ok
@spec setup_ets_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}
@spec setup_ets_isolation(IsolationContext.t(), [table_name()]) :: {:ok, IsolationContext.t()}

def setup_ets_isolation do
  Process.put(:supertester_ets_isolated, true)
  Process.put(:supertester_ets_tables, [])
  Process.put(:supertester_ets_mirrors, %{})
  Process.put(:supertester_ets_injections, [])

  Supertester.Env.on_exit(fn ->
    cleanup_all_tables()
  end)

  emit_setup()
  :ok
end

def setup_ets_isolation(tables) when is_list(tables) do
  :ok = setup_ets_isolation()

  # Auto-mirror specified tables
  for table_name <- tables do
    {:ok, _mirror} = mirror_table(table_name)
  end

  :ok
end

def setup_ets_isolation(%IsolationContext{} = ctx) do
  :ok = setup_ets_isolation()

  updated_ctx = %{ctx |
    isolated_ets_tables: %{},
    ets_mirrors: []
  }

  {:ok, updated_ctx}
end

def setup_ets_isolation(%IsolationContext{} = ctx, tables) when is_list(tables) do
  {:ok, ctx} = setup_ets_isolation(ctx)

  {mirrors, ctx} = Enum.reduce(tables, {[], ctx}, fn table_name, {acc, ctx} ->
    {:ok, mirror} = mirror_table(table_name)
    updated_mirrors = [{table_name, mirror} | ctx.ets_mirrors]
    updated_isolated = Map.put(ctx.isolated_ets_tables, table_name, mirror)
    {[{table_name, mirror} | acc], %{ctx | ets_mirrors: updated_mirrors, isolated_ets_tables: updated_isolated}}
  end)

  {:ok, ctx}
end
```

#### `create_isolated/1` and `create_isolated/2`

Create a new ETS table with automatic cleanup.

```elixir
@spec create_isolated(table_type()) :: {:ok, table_ref()}
@spec create_isolated(table_type(), [table_option() | create_opts()]) :: {:ok, table_ref()}

def create_isolated(type, opts \\ []) do
  ensure_isolation_setup!()

  {create_opts, ets_opts} = Keyword.split(opts, [:name, :copy_from, :owner, :cleanup])

  # Build ETS options
  ets_opts = [type | ets_opts]
  ets_opts = if name = Keyword.get(create_opts, :name) do
    [:named_table | ets_opts]
  else
    ets_opts
  end

  # Create the table
  table = if name = Keyword.get(create_opts, :name) do
    :ets.new(name, ets_opts)
  else
    :ets.new(:supertester_isolated_table, ets_opts)
  end

  # Copy data if requested
  if source = Keyword.get(create_opts, :copy_from) do
    copy_table_data(source, table)
  end

  # Change owner if requested
  if owner = Keyword.get(create_opts, :owner) do
    :ets.give_away(table, owner, :supertester_transfer)
  end

  # Register for cleanup
  if Keyword.get(create_opts, :cleanup, true) do
    register_table_for_cleanup(table)
  end

  emit_created(table)
  {:ok, table}
end
```

#### `mirror_table/1` and `mirror_table/2`

Create an isolated copy of an existing named table.

```elixir
@spec mirror_table(table_name()) :: {:ok, table_ref()}
@spec mirror_table(table_name(), mirror_opts()) :: {:ok, table_ref()}

def mirror_table(source_name, opts \\ []) do
  ensure_isolation_setup!()

  include_data = Keyword.get(opts, :include_data, false)
  access = Keyword.get(opts, :access, :public)
  cleanup = Keyword.get(opts, :cleanup, true)

  # Get source table info
  source_info = :ets.info(source_name)
  if source_info == :undefined do
    {:error, {:table_not_found, source_name}}
  else
    # Determine table type
    type = Keyword.get(source_info, :type)
    keypos = Keyword.get(source_info, :keypos)

    # Create mirror table (unnamed to avoid conflicts)
    mirror_opts = [type, access, {:keypos, keypos}]
    mirror = :ets.new(:supertester_mirror, mirror_opts)

    # Copy data if requested
    if include_data do
      copy_table_data(source_name, mirror)
    end

    # Register mirror mapping
    register_mirror(source_name, mirror)

    # Register for cleanup
    if cleanup do
      register_table_for_cleanup(mirror)
    end

    emit_mirrored(source_name, mirror)
    {:ok, mirror}
  end
end
```

#### `inject_table/3`

Temporarily replace a module's table reference for the duration of the test.

```elixir
@spec inject_table(module(), atom(), table_name() | table_ref()) :: {:ok, (-> :ok)}
@spec inject_table(module(), atom(), table_name() | table_ref(), inject_opts()) :: {:ok, (-> :ok)}

def inject_table(module, function_or_attribute, replacement, opts \\ []) do
  ensure_isolation_setup!()

  create = Keyword.get(opts, :create, true)
  table_opts = Keyword.get(opts, :table_opts, [:set, :public, :named_table])
  cleanup = Keyword.get(opts, :cleanup, true)

  # Create replacement table if requested
  replacement_table = if create and is_atom(replacement) do
    :ets.new(replacement, table_opts)
  else
    replacement
  end

  # Store original for restoration
  original = get_module_table_ref(module, function_or_attribute)
  injection = {module, function_or_attribute, original, replacement_table}
  register_injection(injection)

  # Inject the replacement
  set_module_table_ref(module, function_or_attribute, replacement_table)

  # Create restore function
  restore_fn = fn ->
    set_module_table_ref(module, function_or_attribute, original)
    if create do
      :ets.delete(replacement_table)
    end
    :ok
  end

  # Register for cleanup
  if cleanup do
    Supertester.Env.on_exit(restore_fn)
  end

  emit_injected(module, function_or_attribute, replacement_table)
  {:ok, restore_fn}
end

# Implementation helpers for injection
defp get_module_table_ref(module, function_name) when is_atom(function_name) do
  apply(module, function_name, [])
end

defp set_module_table_ref(module, function_name, table) when is_atom(function_name) do
  # This requires the module to support table injection
  # Pattern: Module must have a __supertester_set_table__/2 function
  # or use Application.put_env for runtime configuration
  cond do
    function_exported?(module, :__supertester_set_table__, 2) ->
      apply(module, :__supertester_set_table__, [function_name, table])

    true ->
      # Fall back to application env
      app = Application.get_application(module)
      key = :"#{module}_#{function_name}"
      Application.put_env(app, key, table)
  end
end
```

#### `with_table/2` and `with_table/3`

Execute a function with a temporary ETS table that is deleted after the scope.

```elixir
@spec with_table(table_type(), (table_ref() -> result)) :: result when result: term()
@spec with_table(table_type(), [table_option()], (table_ref() -> result)) :: result when result: term()

def with_table(type, fun) when is_function(fun, 1) do
  with_table(type, [], fun)
end

def with_table(type, opts, fun) when is_function(fun, 1) do
  {:ok, table} = create_isolated(type, Keyword.put(opts, :cleanup, false))

  try do
    fun.(table)
  after
    safe_delete_table(table)
  end
end
```

#### `get_mirror/1`

Get the mirror table for a source table name.

```elixir
@spec get_mirror(table_name()) :: {:ok, table_ref()} | {:error, :not_mirrored}

def get_mirror(source_name) do
  mirrors = Process.get(:supertester_ets_mirrors, %{})

  case Map.get(mirrors, source_name) do
    nil -> {:error, :not_mirrored}
    mirror -> {:ok, mirror}
  end
end
```

#### `get_mirror!/1`

Get the mirror table or raise.

```elixir
@spec get_mirror!(table_name()) :: table_ref()

def get_mirror!(source_name) do
  case get_mirror(source_name) do
    {:ok, mirror} -> mirror
    {:error, :not_mirrored} ->
      raise ArgumentError, "No mirror exists for table #{inspect(source_name)}"
  end
end
```

---

### Application Code Integration

For `inject_table/3` to work, application modules need to support table injection. Here's the recommended pattern:

#### Pattern 1: Environment-Based Configuration

```elixir
defmodule MyApp.Cache do
  @default_table :myapp_cache

  def table_name do
    Application.get_env(:myapp, :cache_table, @default_table)
  end

  def get(key) do
    :ets.lookup(table_name(), key)
  end

  def put(key, value) do
    :ets.insert(table_name(), {key, value})
  end
end

# In config/test.exs, can set different default
# Or use inject_table/3 to override at runtime
```

#### Pattern 2: Supertester Protocol

```elixir
defmodule MyApp.Cache do
  @table :myapp_cache

  def table_name do
    Process.get(:myapp_cache_override, @table)
  end

  # Called by Supertester.ETSIsolation.inject_table/3
  def __supertester_set_table__(:table_name, table) do
    Process.put(:myapp_cache_override, table)
  end

  def get(key), do: :ets.lookup(table_name(), key)
  def put(key, value), do: :ets.insert(table_name(), {key, value})
end
```

#### Pattern 3: Compile-Time Opt-In

```elixir
defmodule MyApp.Cache do
  use Supertester.InjectableETS, table: :myapp_cache

  def get(key), do: :ets.lookup(table(), key)
  def put(key, value), do: :ets.insert(table(), {key, value})
end

# The use macro generates:
# - def table/0 that checks process dictionary
# - def __supertester_set_table__/2 for injection
```

---

## Usage Examples

### Basic Isolated Table

```elixir
defmodule MyApp.CacheTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation

  test "uses isolated table" do
    {:ok, table} = ETSIsolation.create_isolated(:set, [:public])

    :ets.insert(table, {:key, :value})
    assert :ets.lookup(table, :key) == [{:key, :value}]

    # Table automatically deleted after test
  end
end
```

### Mirroring Application Tables

```elixir
defmodule MyApp.CacheTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation,
    ets_isolation: [:myapp_cache, :myapp_sessions]  # Auto-mirror these

  test "uses mirrored cache", %{isolation_context: ctx} do
    cache = ctx.isolated_ets_tables[:myapp_cache]

    :ets.insert(cache, {:key, :value})
    assert :ets.lookup(cache, :key) == [{:key, :value}]

    # Original :myapp_cache is untouched
    assert :ets.lookup(:myapp_cache, :key) == []
  end
end
```

### Manual Mirroring with Data Copy

```elixir
test "mirrors with existing data" do
  # Setup: populate original table
  :ets.insert(:myapp_cache, {:existing, :data})

  # Mirror with data
  {:ok, mirror} = ETSIsolation.mirror_table(:myapp_cache, include_data: true)

  # Mirror has the data
  assert :ets.lookup(mirror, :existing) == [{:existing, :data}]

  # Modify mirror
  :ets.insert(mirror, {:new, :value})

  # Original unchanged
  assert :ets.lookup(:myapp_cache, :new) == []
end
```

### Table Injection

```elixir
defmodule MyApp.TokenizerTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation

  test "uses injected tokenizer cache" do
    # Create isolated table and inject
    {:ok, _restore} = ETSIsolation.inject_table(
      Tinkex.Tokenizer,
      :cache_table,
      :test_tokenizer_cache,
      table_opts: [:set, :public, :named_table]
    )

    # Now Tinkex.Tokenizer.cache_table() returns :test_tokenizer_cache
    assert Tinkex.Tokenizer.cache_table() == :test_tokenizer_cache

    # Use the tokenizer - all caching goes to isolated table
    Tinkex.Tokenizer.encode("test text", model: "gpt-4")

    # After test, original table reference is restored
  end
end
```

### Scoped Table Usage

```elixir
test "with_table provides scoped access" do
  result = ETSIsolation.with_table(:ordered_set, [:public], fn table ->
    for i <- 1..100 do
      :ets.insert(table, {i, i * 2})
    end

    :ets.foldl(fn {k, v}, acc -> acc + v end, 0, table)
  end)

  assert result == Enum.sum(for i <- 1..100, do: i * 2)
  # Table no longer exists
end
```

### Fixing the encode_test.exs Pattern

Before (flaky):
```elixir
setup do
  ensure_table()
  :ets.delete_all_objects(:tinkex_tokenizers)  # GLOBAL MUTATION!
  {:ok, _} = Application.ensure_all_started(:tokenizers)
  :ok
end
```

After (robust):
```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  ets_isolation: [:tinkex_tokenizers]

setup %{isolation_context: ctx} do
  {:ok, _} = Application.ensure_all_started(:tokenizers)
  {:ok, tokenizer_cache: ctx.isolated_ets_tables[:tinkex_tokenizers]}
end

test "caches tokenizer", %{tokenizer_cache: cache} do
  # Uses isolated cache, original :tinkex_tokenizers untouched
end
```

---

## Implementation Details

### Process Dictionary Keys

```elixir
:supertester_ets_isolated       # boolean - isolation active
:supertester_ets_tables         # [table_ref()] - tables to cleanup
:supertester_ets_mirrors        # %{source_name => mirror_ref}
:supertester_ets_injections     # [{module, attr, original, replacement}]
```

### Cleanup Logic

```elixir
defp cleanup_all_tables do
  # Delete created/mirrored tables
  tables = Process.get(:supertester_ets_tables, [])
  for table <- tables do
    safe_delete_table(table)
  end

  # Restore injections
  injections = Process.get(:supertester_ets_injections, [])
  for {module, attr, original, replacement} <- injections do
    set_module_table_ref(module, attr, original)
    safe_delete_table(replacement)
  end

  # Clear state
  Process.delete(:supertester_ets_isolated)
  Process.delete(:supertester_ets_tables)
  Process.delete(:supertester_ets_mirrors)
  Process.delete(:supertester_ets_injections)

  emit_cleanup_complete()
  :ok
end

defp safe_delete_table(table) do
  try do
    :ets.delete(table)
  catch
    :error, :badarg -> :ok  # Already deleted
  end
end

defp copy_table_data(source, dest) do
  :ets.foldl(fn row, _ ->
    :ets.insert(dest, row)
  end, :ok, source)
end
```

### Telemetry Events

```elixir
[:supertester, :ets, :isolation, :setup]
  measurements: %{}
  metadata: %{pid: pid()}

[:supertester, :ets, :table, :created]
  measurements: %{}
  metadata: %{table: table_ref(), type: table_type()}

[:supertester, :ets, :table, :mirrored]
  measurements: %{row_count: non_neg_integer()}
  metadata: %{source: table_name(), mirror: table_ref()}

[:supertester, :ets, :table, :injected]
  measurements: %{}
  metadata: %{module: module(), attribute: atom(), table: table_ref()}

[:supertester, :ets, :table, :deleted]
  measurements: %{}
  metadata: %{table: table_ref()}

[:supertester, :ets, :cleanup, :complete]
  measurements: %{tables_deleted: non_neg_integer()}
  metadata: %{pid: pid()}
```

---

## Testing the Module Itself

```elixir
defmodule Supertester.ETSIsolationTest do
  use ExUnit.Case, async: true

  alias Supertester.ETSIsolation

  setup do
    ETSIsolation.setup_ets_isolation()
    :ok
  end

  describe "create_isolated/2" do
    test "creates table with automatic cleanup" do
      {:ok, table} = ETSIsolation.create_isolated(:set)

      :ets.insert(table, {:key, :value})
      assert :ets.lookup(table, :key) == [{:key, :value}]

      # Table exists
      assert :ets.info(table) != :undefined
    end

    test "creates named table" do
      {:ok, table} = ETSIsolation.create_isolated(:set, name: :my_test_table)

      assert table == :my_test_table
      assert :ets.info(:my_test_table) != :undefined
    end
  end

  describe "mirror_table/2" do
    setup do
      # Create source table
      :ets.new(:source_table, [:set, :public, :named_table])
      :ets.insert(:source_table, [{:a, 1}, {:b, 2}])

      on_exit(fn -> :ets.delete(:source_table) end)
      :ok
    end

    test "creates empty mirror by default" do
      {:ok, mirror} = ETSIsolation.mirror_table(:source_table)

      assert :ets.info(mirror, :size) == 0
    end

    test "copies data when requested" do
      {:ok, mirror} = ETSIsolation.mirror_table(:source_table, include_data: true)

      assert :ets.info(mirror, :size) == 2
      assert :ets.lookup(mirror, :a) == [{:a, 1}]
    end

    test "modifications don't affect source" do
      {:ok, mirror} = ETSIsolation.mirror_table(:source_table, include_data: true)

      :ets.delete(mirror, :a)
      :ets.insert(mirror, {:c, 3})

      # Source unchanged
      assert :ets.lookup(:source_table, :a) == [{:a, 1}]
      assert :ets.lookup(:source_table, :c) == []
    end
  end

  describe "with_table/3" do
    test "deletes table after scope" do
      table_ref = ETSIsolation.with_table(:set, fn table ->
        :ets.insert(table, {:key, :value})
        table
      end)

      # Table no longer exists
      assert :ets.info(table_ref) == :undefined
    end

    test "returns function result" do
      result = ETSIsolation.with_table(:set, fn table ->
        :ets.insert(table, {:key, :value})
        :ets.lookup(table, :key)
      end)

      assert result == [{:key, :value}]
    end
  end

  describe "concurrent isolation" do
    test "parallel tests have independent tables" do
      tasks = for i <- 1..10 do
        Task.async(fn ->
          ETSIsolation.setup_ets_isolation()
          {:ok, table} = ETSIsolation.create_isolated(:set)

          :ets.insert(table, {:id, i})
          Process.sleep(10)  # Simulate work
          :ets.lookup(table, :id)
        end)
      end

      results = Task.await_many(tasks)

      # Each task should have its own isolated value
      for {result, i} <- Enum.with_index(results, 1) do
        assert result == [{:id, i}]
      end
    end
  end
end
```

---

## Integration with IsolationContext

The IsolationContext struct is extended:

```elixir
defstruct [
  # ... existing fields ...

  # ETS isolation state
  isolated_ets_tables: %{},  # %{original_name => isolated_ref}
  ets_mirrors: []            # [{source_name, mirror_ref}]
]
```

---

## InjectableETS Macro (Optional Helper)

For easy opt-in to table injection:

```elixir
defmodule Supertester.InjectableETS do
  @moduledoc """
  Macro to make module ETS tables injectable for testing.

  Usage:
      defmodule MyApp.Cache do
        use Supertester.InjectableETS, table: :myapp_cache

        def get(key), do: :ets.lookup(table(), key)
      end
  """

  defmacro __using__(opts) do
    default_table = Keyword.fetch!(opts, :table)

    quote do
      @default_table unquote(default_table)

      def table do
        Process.get({__MODULE__, :table_override}, @default_table)
      end

      def __supertester_set_table__(:table, table_ref) do
        if table_ref == @default_table do
          Process.delete({__MODULE__, :table_override})
        else
          Process.put({__MODULE__, :table_override}, table_ref)
        end
        :ok
      end

      def __supertester_reset_table__ do
        Process.delete({__MODULE__, :table_override})
        :ok
      end
    end
  end
end
```

---

## Migration Notes

### From :ets.delete_all_objects in Setup

Before:
```elixir
setup do
  :ets.delete_all_objects(:myapp_cache)
  :ok
end
```

After:
```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  ets_isolation: [:myapp_cache]

# No setup needed - each test gets isolated mirror
```

### From Manual Table Creation

Before:
```elixir
setup do
  table = :ets.new(:test_table, [:set, :public])
  on_exit(fn ->
    try do
      :ets.delete(table)
    catch
      :error, :badarg -> :ok
    end
  end)
  {:ok, table: table}
end
```

After:
```elixir
setup do
  {:ok, table} = ETSIsolation.create_isolated(:set, [:public])
  {:ok, table: table}
  # Cleanup is automatic
end
```

### From async: false Due to ETS

Before:
```elixir
use ExUnit.Case, async: false  # Can't run async due to shared ETS
```

After:
```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  ets_isolation: [:shared_table]
# Now safely async!
```
