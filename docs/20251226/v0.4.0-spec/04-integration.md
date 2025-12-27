# Module Integration and Composition

## Overview

The three new v0.4.0 modules (TelemetryHelpers, LoggerIsolation, ETSIsolation) are designed to work together seamlessly with existing Supertester infrastructure. This document describes integration patterns and composition strategies.

---

## ExUnitFoundation Integration

### Combined Configuration

```elixir
use Supertester.ExUnitFoundation,
  # Existing options
  isolation: :full_isolation,

  # NEW v0.4.0 options
  telemetry_isolation: true,
  logger_isolation: true,
  ets_isolation: [:myapp_cache, :myapp_sessions, :myapp_tokens]
```

### Setup Flow

When a test module uses ExUnitFoundation with v0.4.0 options, the setup flow is:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ExUnitFoundation.setup                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            1. UnifiedTestFoundation.setup_isolation              │
│               Creates IsolationContext                           │
│               Tracks initial processes/ETS tables                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            2. TelemetryHelpers.setup_telemetry_isolation         │
│               (if telemetry_isolation: true)                     │
│               Generates telemetry_test_id                        │
│               Stores in process dictionary                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            3. LoggerIsolation.setup_logger_isolation             │
│               (if logger_isolation: true)                        │
│               Records original level                             │
│               Registers cleanup                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            4. ETSIsolation.setup_ets_isolation                   │
│               (if ets_isolation: [...])                          │
│               Mirrors specified tables                           │
│               Registers cleanup                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            5. Tag-based configuration                            │
│               @tag logger_level: :debug                          │
│               @tag telemetry_events: [...]                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            6. Test execution                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            7. Cleanup (on_exit callbacks, reverse order)         │
│               - ETS tables deleted                               │
│               - Logger level restored                            │
│               - Telemetry handlers detached                      │
│               - Processes terminated                             │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation in ExUnitFoundation

```elixir
defmodule Supertester.ExUnitFoundation do
  defmacro __using__(opts) do
    isolation = Keyword.get(opts, :isolation, :basic)
    telemetry_isolation = Keyword.get(opts, :telemetry_isolation, false)
    logger_isolation = Keyword.get(opts, :logger_isolation, false)
    ets_isolation = Keyword.get(opts, :ets_isolation, [])

    quote do
      use ExUnit.Case, async: unquote(isolation_allows_async?(isolation))

      setup context do
        # 1. Base isolation
        {:ok, base_ctx} = UnifiedTestFoundation.setup_isolation(
          unquote(isolation),
          context
        )

        # 2. Telemetry isolation
        ctx = if unquote(telemetry_isolation) do
          {:ok, _test_id, ctx} = TelemetryHelpers.setup_telemetry_isolation(base_ctx)
          ctx
        else
          base_ctx
        end

        # 3. Logger isolation
        ctx = if unquote(logger_isolation) do
          {:ok, ctx} = LoggerIsolation.setup_logger_isolation(ctx)

          # Apply tag-based level
          if level = context[:logger_level] do
            LoggerIsolation.isolate_level(level)
          end

          ctx
        else
          ctx
        end

        # 4. ETS isolation
        ctx = if unquote(ets_isolation) != [] do
          {:ok, ctx} = ETSIsolation.setup_ets_isolation(ctx, unquote(ets_isolation))
          ctx
        else
          ctx
        end

        # 5. Auto-attach telemetry events from tag
        if events = context[:telemetry_events] do
          TelemetryHelpers.attach_isolated(events)
        end

        {:ok, isolation_context: ctx}
      end
    end
  end
end
```

---

## IsolationContext Extensions

### Complete v0.4.0 Struct

```elixir
defmodule Supertester.IsolationContext do
  @moduledoc """
  Tracks all isolation state for a single test.
  """

  defstruct [
    # === Existing v0.3.x fields ===
    test_id: nil,
    registry: nil,
    processes: [],
    ets_tables: [],
    cleanup_callbacks: [],
    initial_processes: [],
    initial_ets_tables: [],
    tags: %{},

    # === NEW v0.4.0 fields ===

    # Telemetry isolation
    telemetry_test_id: nil,        # Unique ID for filtering
    telemetry_handlers: [],        # [{handler_id, events}]

    # Logger isolation
    logger_original_level: nil,    # Level before isolation
    logger_isolated?: false,       # Active flag

    # ETS isolation
    isolated_ets_tables: %{},      # %{original_name => isolated_ref}
    ets_mirrors: [],               # [{source, mirror}]
    ets_injections: []             # [{module, attr, original, replacement}]
  ]

  @type t :: %__MODULE__{
    test_id: integer() | nil,
    registry: atom() | nil,
    processes: [process_info()],
    ets_tables: [term()],
    cleanup_callbacks: [(() -> any())],
    initial_processes: [pid()],
    initial_ets_tables: [atom()],
    tags: map(),

    # v0.4.0
    telemetry_test_id: integer() | nil,
    telemetry_handlers: [{String.t(), [atom()]}],
    logger_original_level: Logger.level() | nil,
    logger_isolated?: boolean(),
    isolated_ets_tables: %{atom() => :ets.tid()},
    ets_mirrors: [{atom(), :ets.tid()}],
    ets_injections: [{module(), atom(), term(), term()}]
  }
end
```

### Context Access Helpers

```elixir
defmodule Supertester.IsolationContext do
  # ... struct definition ...

  @doc "Get the isolated ETS table for a source table name"
  def get_ets_table(%__MODULE__{isolated_ets_tables: tables}, source_name) do
    Map.get(tables, source_name)
  end

  @doc "Get the telemetry test ID for filtering"
  def telemetry_id(%__MODULE__{telemetry_test_id: id}), do: id

  @doc "Check if logger isolation is active"
  def logger_isolated?(%__MODULE__{logger_isolated?: flag}), do: flag

  @doc "List all telemetry handler IDs"
  def telemetry_handlers(%__MODULE__{telemetry_handlers: handlers}) do
    Enum.map(handlers, fn {id, _events} -> id end)
  end
end
```

---

## Tag-Based Configuration

### Supported Tags

```elixir
# Logger level for this test
@tag logger_level: :debug

# Auto-attach telemetry handlers for these events
@tag telemetry_events: [[:myapp, :request, :start], [:myapp, :request, :stop]]

# Additional ETS tables to mirror (beyond module-level config)
@tag ets_tables: [:additional_cache]
```

### Tag Processing in Setup

```elixir
setup context do
  ctx = context[:isolation_context]

  # Logger level tag
  if level = context[:logger_level] do
    LoggerIsolation.isolate_level(level)
  end

  # Telemetry events tag
  if events = context[:telemetry_events] do
    for event <- List.wrap(events) do
      TelemetryHelpers.attach_isolated(event)
    end
  end

  # Additional ETS tables tag
  if tables = context[:ets_tables] do
    for table <- tables do
      {:ok, _} = ETSIsolation.mirror_table(table)
    end
  end

  :ok
end
```

---

## Module Interoperability

### Telemetry + Logger

Capture logs and telemetry together:

```elixir
test "logs and emits telemetry on request" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :request, :done])

  {log, _result} = LoggerIsolation.capture_isolated(:debug, fn ->
    MyApp.Service.make_request(%{id: "test"})
  end)

  # Both assertions work without interference from other tests
  assert log =~ "Processing request"
  assert_telemetry [:myapp, :request, :done], %{request_id: "test"}
end
```

### Telemetry + ETS

Test caching behavior with isolated state:

```elixir
test "caches result and emits telemetry", %{isolation_context: ctx} do
  cache = ctx.isolated_ets_tables[:myapp_cache]
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :cache, :hit])

  # First call - cache miss
  result1 = MyApp.Service.cached_operation(:key)
  refute_telemetry [:myapp, :cache, :hit], timeout: 50

  # Manually populate cache
  :ets.insert(cache, {:key, result1})

  # Second call - cache hit
  result2 = MyApp.Service.cached_operation(:key)
  assert result1 == result2
  assert_telemetry [:myapp, :cache, :hit]
end
```

### All Three Together

```elixir
defmodule MyApp.IntegrationTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation,
    telemetry_isolation: true,
    logger_isolation: true,
    ets_isolation: [:myapp_cache, :myapp_tokens]

  @tag logger_level: :debug
  test "full isolation", %{isolation_context: ctx} do
    # Attach telemetry
    {:ok, _} = TelemetryHelpers.attach_isolated([
      [:myapp, :request, :start],
      [:myapp, :request, :done],
      [:myapp, :cache, :miss]
    ])

    # Get isolated tables
    cache = ctx.isolated_ets_tables[:myapp_cache]
    tokens = ctx.isolated_ets_tables[:myapp_tokens]

    # Prepopulate token cache
    :ets.insert(tokens, {"user-1", "valid-token"})

    # Capture logs
    {log, result} = LoggerIsolation.capture_isolated(:debug, fn ->
      MyApp.Service.authenticated_request("user-1", :operation)
    end)

    # All assertions isolated from concurrent tests
    assert {:ok, _} = result
    assert log =~ "Authenticated user-1"
    assert log =~ "Cache miss for operation"

    assert_telemetry [:myapp, :request, :start]
    assert_telemetry [:myapp, :cache, :miss]
    assert_telemetry [:myapp, :request, :done], %{status: :success}

    # Verify cache was populated
    assert :ets.lookup(cache, :operation) != []
  end
end
```

---

## Integration with ConcurrentHarness

### Telemetry in Concurrent Scenarios

```elixir
test "concurrent operations emit proper telemetry" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :operation, :done])

  scenario = ConcurrentHarness.simple_genserver_scenario(
    MyApp.Worker,
    [:process, :process, :process],
    3,  # 3 threads
    invariant: fn _pid, _state -> :ok end
  )

  {:ok, report} = ConcurrentHarness.run(scenario)
  assert report.status == :ok

  # Should receive 9 telemetry events (3 threads x 3 operations)
  events = TelemetryHelpers.assert_telemetry_count([:myapp, :operation, :done], 9)
  assert length(events) == 9
end
```

### ETS in Concurrent Scenarios

```elixir
test "concurrent cache access" do
  {:ok, cache} = ETSIsolation.create_isolated(:set, [:public, {:write_concurrency, true}])

  scenario = %ConcurrentHarness.Scenario{
    setup: fn -> {:ok, cache} end,
    threads: [
      [{:custom, fn c -> :ets.insert(c, {:a, 1}) end}],
      [{:custom, fn c -> :ets.insert(c, {:b, 2}) end}],
      [{:custom, fn c -> :ets.insert(c, {:c, 3}) end}]
    ],
    invariant: fn cache, _state ->
      # All inserts should be visible
      size = :ets.info(cache, :size)
      assert size == 3
    end,
    timeout_ms: 5000
  }

  {:ok, _} = ConcurrentHarness.run(scenario)
end
```

---

## Integration with ChaosHelpers

### Chaos Testing with Isolation

```elixir
test "survives chaos with isolated state" do
  {:ok, cache} = ETSIsolation.create_isolated(:set, [:public])
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :recovery])

  {:ok, sup} = start_supervised!({MyApp.Supervisor, cache: cache})

  report = ChaosHelpers.chaos_kill_children(sup,
    kill_rate: 0.5,
    duration_ms: 2000
  )

  assert report.supervisor_crashed == false
  assert report.restarted > 0

  # Should emit recovery telemetry for each restart
  events = TelemetryHelpers.flush_telemetry(:all)
  recovery_events = Enum.filter(events, fn {:telemetry, event, _, _} ->
    event == [:myapp, :recovery]
  end)

  assert length(recovery_events) == report.restarted
end
```

---

## Isolation Level Compatibility

### Full Isolation (Recommended)

```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  telemetry_isolation: true,
  logger_isolation: true,
  ets_isolation: [:table1, :table2]

# All features work, async: true
```

### Registry Isolation

```elixir
use Supertester.ExUnitFoundation,
  isolation: :registry,
  telemetry_isolation: true,
  logger_isolation: true
  # ets_isolation works but tables still global - use create_isolated

# async: true
```

### Basic Isolation

```elixir
use Supertester.ExUnitFoundation,
  isolation: :basic,
  telemetry_isolation: true,
  logger_isolation: true
  # ets_isolation works with create_isolated/mirror_table

# async: true
```

### Contamination Detection

```elixir
use Supertester.ExUnitFoundation,
  isolation: :contamination_detection,
  telemetry_isolation: true,
  logger_isolation: true,
  ets_isolation: [:watched_table]

# async: false (required for contamination detection)
# Will report if any global state leaked
```

---

## Telemetry Events Summary

All v0.4.0 modules emit telemetry for observability:

```elixir
# TelemetryHelpers
[:supertester, :telemetry, :handler, :attached]
[:supertester, :telemetry, :handler, :detached]
[:supertester, :telemetry, :event, :filtered]
[:supertester, :telemetry, :event, :delivered]

# LoggerIsolation
[:supertester, :logger, :isolation, :setup]
[:supertester, :logger, :level, :set]
[:supertester, :logger, :level, :restored]

# ETSIsolation
[:supertester, :ets, :isolation, :setup]
[:supertester, :ets, :table, :created]
[:supertester, :ets, :table, :mirrored]
[:supertester, :ets, :table, :injected]
[:supertester, :ets, :table, :deleted]
[:supertester, :ets, :cleanup, :complete]
```

These events integrate with existing Supertester telemetry under the `[:supertester, ...]` prefix.

---

## Error Handling

### Missing Setup Errors

All modules check for proper setup and provide helpful error messages:

```elixir
# TelemetryHelpers
TelemetryHelpers.attach_isolated([:event])
# ** (RuntimeError) Telemetry isolation not set up. Call setup_telemetry_isolation/0 first.

# LoggerIsolation
LoggerIsolation.isolate_level(:debug)
# ** (ArgumentError) Logger isolation not set up for this process.
#
# To fix, either:
# 1. Add `logger_isolation: true` to your ExUnitFoundation use
# 2. Or call setup explicitly in your test setup

# ETSIsolation
ETSIsolation.create_isolated(:set)
# ** (RuntimeError) ETS isolation not set up. Call setup_ets_isolation/0 first.
```

### Table Not Found

```elixir
ETSIsolation.mirror_table(:nonexistent_table)
# => {:error, {:table_not_found, :nonexistent_table}}
```

### Cleanup Failures

Cleanup functions are defensive and don't raise:

```elixir
# All cleanup operations use try/catch
# Failed cleanups are logged but don't fail the test
```
