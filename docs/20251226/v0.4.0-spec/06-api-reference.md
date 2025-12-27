# Supertester v0.4.0 API Reference

## New Modules

---

## Supertester.TelemetryHelpers

Async-safe telemetry testing with per-test event isolation.

### Setup Functions

#### `setup_telemetry_isolation/0`

```elixir
@spec setup_telemetry_isolation() :: {:ok, test_id :: integer()}
```

Initialize telemetry isolation for the current test process. Generates a unique test ID and stores it in the process dictionary.

**Returns**: `{:ok, test_id}` where `test_id` is a unique integer.

**Example**:
```elixir
setup do
  {:ok, test_id} = TelemetryHelpers.setup_telemetry_isolation()
  {:ok, test_id: test_id}
end
```

#### `setup_telemetry_isolation/1`

```elixir
@spec setup_telemetry_isolation(IsolationContext.t()) :: {:ok, integer(), IsolationContext.t()}
```

Initialize telemetry isolation and update the IsolationContext.

**Parameters**:
- `ctx` - Existing IsolationContext struct

**Returns**: `{:ok, test_id, updated_context}`

---

### Handler Functions

#### `attach_isolated/1`

```elixir
@spec attach_isolated(event :: [atom()] | [[atom()]]) :: {:ok, handler_id :: String.t()}
```

Attach a telemetry handler that only receives events with matching test ID.

**Parameters**:
- `events` - Single event or list of events to handle

**Returns**: `{:ok, handler_id}`

**Example**:
```elixir
{:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :request, :done])
```

#### `attach_isolated/2`

```elixir
@spec attach_isolated(events, opts) :: {:ok, String.t()}
  when events: [atom()] | [[atom()]],
       opts: [
         filter_key: atom(),
         passthrough: boolean(),
         buffer: boolean(),
         transform: (message -> term())
       ]
```

Attach handler with options.

**Options**:
- `:filter_key` - Metadata key for test ID (default: `:supertester_test_id`)
- `:passthrough` - Also receive events without test ID (default: `false`)
- `:buffer` - Buffer events instead of sending immediately (default: `false`)
- `:transform` - Transform function for messages before delivery

**Example**:
```elixir
{:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :event], passthrough: true)
```

---

### Context Functions

#### `get_test_id/0`

```elixir
@spec get_test_id() :: integer() | nil
```

Get the current test's telemetry ID, or nil if not set.

#### `get_test_id!/0`

```elixir
@spec get_test_id!() :: integer()
```

Get the current test's telemetry ID, raising if not set.

#### `current_test_metadata/0`

```elixir
@spec current_test_metadata() :: map()
```

Get metadata map with current test's ID for inclusion in telemetry events.

**Returns**: `%{supertester_test_id: id}` or `%{}` if not set.

#### `current_test_metadata/1`

```elixir
@spec current_test_metadata(map()) :: map()
```

Merge test ID into existing metadata map.

---

### Assertion Macros

#### `assert_telemetry/1`

```elixir
defmacro assert_telemetry(event_pattern)
```

Assert a telemetry event matching the pattern was received.

**Example**:
```elixir
assert_telemetry [:myapp, :request, :done]
```

#### `assert_telemetry/2`

```elixir
defmacro assert_telemetry(event_pattern, metadata_pattern_or_opts)
```

Assert telemetry with metadata pattern or options.

**Example**:
```elixir
assert_telemetry [:myapp, :request, :done], %{status: 200}
assert_telemetry [:myapp, :request, :done], timeout: 5000
```

#### `assert_telemetry/3`

```elixir
defmacro assert_telemetry(event_pattern, metadata_pattern, opts)
```

Full form with event, metadata, and options.

**Options**:
- `:timeout` - Assertion timeout in ms (default: 1000)

**Example**:
```elixir
assert_telemetry [:myapp, :request, :done], %{status: 200}, timeout: 5000
```

#### `refute_telemetry/1`

```elixir
defmacro refute_telemetry(event_pattern)
```

Assert NO telemetry event matching the pattern was received.

#### `refute_telemetry/2`

```elixir
defmacro refute_telemetry(event_pattern, opts)
```

Refute with timeout option (default: 100ms).

#### `assert_telemetry_count/2`

```elixir
@spec assert_telemetry_count(event, count) :: [telemetry_message]
  when event: [atom()],
       count: pos_integer()
```

Assert exactly N events were received.

#### `assert_telemetry_count/3`

```elixir
@spec assert_telemetry_count(event, count, opts) :: [telemetry_message]
```

With options including `:timeout`.

---

### Utility Functions

#### `flush_telemetry/1`

```elixir
@spec flush_telemetry(:all | [atom()]) :: [telemetry_message]
```

Remove and return all telemetry messages from the mailbox.

**Example**:
```elixir
events = TelemetryHelpers.flush_telemetry(:all)
```

#### `with_telemetry/2`

```elixir
@spec with_telemetry(events, fun) :: {result, [telemetry_message]}
```

Execute function and capture emitted telemetry.

**Example**:
```elixir
{result, events} = TelemetryHelpers.with_telemetry([:myapp, :event], fn ->
  MyApp.do_work()
end)
```

#### `with_telemetry/3`

```elixir
@spec with_telemetry(events, fun, opts) :: {result, [telemetry_message]}
```

With additional options.

#### `emit_with_context/3`

```elixir
@spec emit_with_context(event, measurements, metadata) :: :ok
```

Emit telemetry with current test's ID automatically included.

**Example**:
```elixir
TelemetryHelpers.emit_with_context([:myapp, :custom], %{value: 42}, %{source: "test"})
```

---

## Supertester.LoggerIsolation

Per-process Logger level management.

### Setup Functions

#### `setup_logger_isolation/0`

```elixir
@spec setup_logger_isolation() :: :ok
```

Initialize logger isolation for the current process.

#### `setup_logger_isolation/1`

```elixir
@spec setup_logger_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}
```

Initialize and update IsolationContext.

---

### Level Functions

#### `isolate_level/1`

```elixir
@spec isolate_level(level) :: :ok
  when level: :emergency | :alert | :critical | :error | :warning | :notice | :info | :debug | :all | :none
```

Set Logger level for the current process only.

**Example**:
```elixir
LoggerIsolation.isolate_level(:debug)
```

#### `isolate_level/2`

```elixir
@spec isolate_level(level, opts) :: :ok
  when opts: [cleanup: boolean()]
```

With options. `:cleanup` controls automatic restoration (default: `true`).

#### `restore_level/0`

```elixir
@spec restore_level() :: :ok
```

Restore the process's Logger level to its original state.

#### `get_isolated_level/0`

```elixir
@spec get_isolated_level() :: level() | nil
```

Get the current process's isolated level.

#### `isolated?/0`

```elixir
@spec isolated?() :: boolean()
```

Check if logger isolation is active.

---

### Capture Functions

#### `capture_isolated/2`

```elixir
@spec capture_isolated(level, fun) :: {log :: String.t(), result}
```

Capture logs at specified level with automatic isolation.

**Example**:
```elixir
{log, result} = LoggerIsolation.capture_isolated(:debug, fn ->
  Logger.debug("message")
  :ok
end)
```

#### `capture_isolated/3`

```elixir
@spec capture_isolated(level, fun, opts) :: {String.t(), result}
  when opts: [colors: boolean(), format: String.t(), metadata: [atom()]]
```

With capture options.

#### `capture_isolated!/2`

```elixir
@spec capture_isolated!(level, fun) :: String.t()
```

Same as `capture_isolated/2` but returns only the log string.

#### `capture_isolated!/3`

```elixir
@spec capture_isolated!(level, fun, opts) :: String.t()
```

With options.

---

### Scoped Functions

#### `with_level/2`

```elixir
@spec with_level(level, fun) :: result
```

Execute function with temporary Logger level.

**Example**:
```elixir
result = LoggerIsolation.with_level(:error, fn ->
  # Only :error and above logged
  :ok
end)
```

#### `with_level_and_capture/2`

```elixir
@spec with_level_and_capture(level, fun) :: {String.t(), result}
```

Execute with temporary level and capture logs.

---

## Supertester.ETSIsolation

Per-test ETS table management.

### Setup Functions

#### `setup_ets_isolation/0`

```elixir
@spec setup_ets_isolation() :: :ok
```

Initialize ETS isolation for the current test.

#### `setup_ets_isolation/1` (list)

```elixir
@spec setup_ets_isolation([atom()]) :: :ok
```

Initialize and auto-mirror specified tables.

**Example**:
```elixir
ETSIsolation.setup_ets_isolation([:myapp_cache, :myapp_sessions])
```

#### `setup_ets_isolation/1` (context)

```elixir
@spec setup_ets_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}
```

Initialize and update IsolationContext.

#### `setup_ets_isolation/2`

```elixir
@spec setup_ets_isolation(IsolationContext.t(), [atom()]) :: {:ok, IsolationContext.t()}
```

Initialize, auto-mirror tables, and update context.

---

### Table Creation

#### `create_isolated/1`

```elixir
@spec create_isolated(type) :: {:ok, table_ref}
  when type: :set | :ordered_set | :bag | :duplicate_bag
```

Create an isolated ETS table with automatic cleanup.

**Example**:
```elixir
{:ok, table} = ETSIsolation.create_isolated(:set)
```

#### `create_isolated/2`

```elixir
@spec create_isolated(type, opts) :: {:ok, table_ref}
  when opts: [
    :public | :protected | :private |
    :named_table |
    {:keypos, pos_integer()} |
    {:read_concurrency, boolean()} |
    {:write_concurrency, boolean()} |
    {:name, atom()} |
    {:copy_from, table_ref()} |
    {:owner, pid()} |
    {:cleanup, boolean()}
  ]
```

With ETS options and creation options.

**Example**:
```elixir
{:ok, table} = ETSIsolation.create_isolated(:set, [
  :public,
  {:write_concurrency, true},
  name: :my_test_table
])
```

---

### Table Mirroring

#### `mirror_table/1`

```elixir
@spec mirror_table(source_name :: atom()) :: {:ok, table_ref} | {:error, {:table_not_found, atom()}}
```

Create an isolated copy of an existing named table.

**Example**:
```elixir
{:ok, mirror} = ETSIsolation.mirror_table(:myapp_cache)
```

#### `mirror_table/2`

```elixir
@spec mirror_table(source_name, opts) :: {:ok, table_ref} | {:error, term()}
  when opts: [
    include_data: boolean(),
    access: :public | :protected | :private,
    cleanup: boolean()
  ]
```

**Options**:
- `:include_data` - Copy existing data (default: `false`)
- `:access` - Access level for mirror (default: `:public`)
- `:cleanup` - Register automatic cleanup (default: `true`)

**Example**:
```elixir
{:ok, mirror} = ETSIsolation.mirror_table(:myapp_cache, include_data: true)
```

---

### Table Injection

#### `inject_table/3`

```elixir
@spec inject_table(module, function_or_attr, replacement) :: {:ok, restore_fn}
  when restore_fn: (-> :ok)
```

Temporarily replace a module's table reference.

**Example**:
```elixir
{:ok, restore} = ETSIsolation.inject_table(MyApp.Cache, :table_name, :test_cache)
# MyApp.Cache.table_name() now returns :test_cache
```

#### `inject_table/4`

```elixir
@spec inject_table(module, function_or_attr, replacement, opts) :: {:ok, restore_fn}
  when opts: [
    create: boolean(),
    table_opts: [table_option()],
    cleanup: boolean()
  ]
```

**Options**:
- `:create` - Create the replacement table (default: `true`)
- `:table_opts` - Options for created table (default: `[:set, :public, :named_table]`)
- `:cleanup` - Restore original on cleanup (default: `true`)

---

### Mirror Access

#### `get_mirror/1`

```elixir
@spec get_mirror(source_name :: atom()) :: {:ok, table_ref} | {:error, :not_mirrored}
```

Get the mirror table for a source table name.

#### `get_mirror!/1`

```elixir
@spec get_mirror!(source_name :: atom()) :: table_ref
```

Get mirror or raise if not found.

---

### Scoped Access

#### `with_table/2`

```elixir
@spec with_table(type, fun) :: result
  when fun: (table_ref -> result)
```

Execute function with temporary table that is deleted after.

**Example**:
```elixir
result = ETSIsolation.with_table(:set, fn table ->
  :ets.insert(table, {:key, :value})
  :ets.lookup(table, :key)
end)
# table is deleted here
```

#### `with_table/3`

```elixir
@spec with_table(type, opts, fun) :: result
```

With ETS options.

---

## IsolationContext Extensions

### New Fields (v0.4.0)

```elixir
defstruct [
  # ... existing fields ...

  # Telemetry
  telemetry_test_id: nil,        # integer() | nil
  telemetry_handlers: [],        # [{handler_id, events}]

  # Logger
  logger_original_level: nil,    # level() | nil
  logger_isolated?: false,       # boolean()

  # ETS
  isolated_ets_tables: %{},      # %{atom() => table_ref()}
  ets_mirrors: [],               # [{source, mirror}]
  ets_injections: []             # [{module, attr, original, replacement}]
]
```

### Accessor Functions

#### `get_ets_table/2`

```elixir
@spec get_ets_table(IsolationContext.t(), atom()) :: table_ref() | nil
```

Get isolated ETS table by source name.

#### `telemetry_id/1`

```elixir
@spec telemetry_id(IsolationContext.t()) :: integer() | nil
```

Get telemetry test ID.

#### `logger_isolated?/1`

```elixir
@spec logger_isolated?(IsolationContext.t()) :: boolean()
```

Check if logger isolation is active.

#### `telemetry_handlers/1`

```elixir
@spec telemetry_handlers(IsolationContext.t()) :: [String.t()]
```

List telemetry handler IDs.

---

## ExUnitFoundation Options

### New Options (v0.4.0)

```elixir
use Supertester.ExUnitFoundation,
  # Existing
  isolation: :full_isolation,

  # NEW
  telemetry_isolation: true,     # Enable TelemetryHelpers setup
  logger_isolation: true,        # Enable LoggerIsolation setup
  ets_isolation: [:table1, :table2]  # Tables to auto-mirror
```

### Supported Tags

```elixir
@tag logger_level: :debug           # Set process Logger level
@tag telemetry_events: [[:a, :b]]   # Auto-attach handlers
@tag ets_tables: [:extra_table]     # Additional tables to mirror
```

---

## Telemetry Events

All v0.4.0 modules emit telemetry under `[:supertester, ...]`:

### TelemetryHelpers Events

```elixir
[:supertester, :telemetry, :handler, :attached]
  metadata: %{handler_id: String.t(), events: [[atom()]], test_id: integer()}

[:supertester, :telemetry, :handler, :detached]
  metadata: %{handler_id: String.t()}

[:supertester, :telemetry, :event, :filtered]
  measurements: %{count: 1}
  metadata: %{event: [atom()], event_test_id: integer() | nil, handler_test_id: integer()}

[:supertester, :telemetry, :event, :delivered]
  measurements: %{count: 1}
  metadata: %{event: [atom()], test_id: integer()}
```

### LoggerIsolation Events

```elixir
[:supertester, :logger, :isolation, :setup]
  metadata: %{pid: pid()}

[:supertester, :logger, :level, :set]
  metadata: %{pid: pid(), level: atom()}

[:supertester, :logger, :level, :restored]
  metadata: %{pid: pid()}
```

### ETSIsolation Events

```elixir
[:supertester, :ets, :isolation, :setup]
  metadata: %{pid: pid()}

[:supertester, :ets, :table, :created]
  metadata: %{table: table_ref(), type: atom()}

[:supertester, :ets, :table, :mirrored]
  measurements: %{row_count: non_neg_integer()}
  metadata: %{source: atom(), mirror: table_ref()}

[:supertester, :ets, :table, :injected]
  metadata: %{module: module(), attribute: atom(), table: table_ref()}

[:supertester, :ets, :table, :deleted]
  metadata: %{table: table_ref()}

[:supertester, :ets, :cleanup, :complete]
  measurements: %{tables_deleted: non_neg_integer()}
  metadata: %{pid: pid()}
```

---

## Type Definitions

### TelemetryHelpers Types

```elixir
@type event :: [atom()]
@type measurements :: map()
@type metadata :: map()
@type handler_id :: String.t()
@type test_id :: integer()
@type telemetry_message :: {:telemetry, event(), measurements(), metadata()}
```

### LoggerIsolation Types

```elixir
@type level :: :emergency | :alert | :critical | :error | :warning | :notice | :info | :debug
@type level_or_all :: level() | :all | :none
```

### ETSIsolation Types

```elixir
@type table_type :: :set | :ordered_set | :bag | :duplicate_bag
@type table_access :: :public | :protected | :private
@type table_ref :: :ets.tid() | atom()
@type table_name :: atom()
```
