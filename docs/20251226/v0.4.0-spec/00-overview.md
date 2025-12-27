# Supertester v0.4.0 Specification

## Release: Global State Isolation Suite

**Version**: 0.4.0
**Status**: Specification
**Date**: 2025-12-26
**Breaking Changes**: None (additive release)

---

## Executive Summary

Supertester v0.4.0 introduces the **Global State Isolation Suite** - three new modules that eliminate the remaining sources of test flakiness in async Elixir test suites:

| Module | Problem Solved |
|--------|----------------|
| `Supertester.TelemetryHelpers` | Telemetry events from concurrent tests polluting each other's assertions |
| `Supertester.LoggerIsolation` | Global Logger level changes affecting concurrent tests |
| `Supertester.ETSIsolation` | Shared ETS tables causing state leakage between tests |

These modules complete Supertester's mission: **100% async-safe OTP testing with zero Process.sleep**.

---

## Problem Statement

### The Three Remaining Flakiness Vectors

Even with Supertester v0.3.1's process isolation, three global state vectors cause intermittent test failures:

#### 1. Telemetry Cross-Talk

```elixir
# Test A attaches handler for [:myapp, :request, :done]
# Test B emits [:myapp, :request, :done] with different metadata
# Test A receives Test B's event and fails assertion

test "emits telemetry on success", %{config: config} do
  :telemetry.attach("handler", [:myapp, :request, :done], &send_to_self/4, nil)
  do_request(config)
  assert_receive {:telemetry, _, _, %{request_id: "expected-id"}}  # FLAKY!
end
```

#### 2. Logger Level Contamination

```elixir
# Test A sets Logger to :debug globally
# Test B's capture_log misses events because level changed mid-capture

test "logs debug info" do
  Logger.configure(level: :debug)  # Affects ALL processes!
  log = capture_log(fn -> do_work() end)
  assert log =~ "debug message"  # FLAKY!
end
```

#### 3. ETS Table State Leakage

```elixir
# Test A clears shared cache table
# Test B was using cached data that just disappeared

setup do
  :ets.delete_all_objects(:myapp_cache)  # Nukes concurrent test's data!
  :ok
end
```

---

## Solution Architecture

### Design Principles

1. **Per-Test Isolation by Default**: Each test gets isolated views of global state
2. **Zero Global Mutation**: No test modifies truly global state
3. **Automatic Cleanup**: All isolation state cleaned up via existing `on_exit` patterns
4. **Backward Compatible**: Existing tests continue to work unchanged
5. **Composable**: Each module works independently or together

### Integration with Existing Infrastructure

```
┌─────────────────────────────────────────────────────────────────┐
│                    ExUnitFoundation                              │
│  use Supertester.ExUnitFoundation, isolation: :full_isolation   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  UnifiedTestFoundation                           │
│  setup_isolation/2 → IsolationContext                           │
└─────────────────────────────────────────────────────────────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
    ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
    │ TelemetryHelpers │ LoggerIsolation │ ETSIsolation │
    │                │ │               │ │              │
    │ • attach_isolated │ • isolate_level │ • create_isolated │
    │ • assert_telemetry │ • capture_isolated │ • mirror_table │
    │ • flush_telemetry │ • with_level    │ • with_table   │
    └───────────────┘ └───────────────┘ └───────────────┘
            │                 │                 │
            └─────────────────┼─────────────────┘
                              ▼
                    ┌───────────────────┐
                    │  IsolationContext  │
                    │  (extended struct) │
                    └───────────────────┘
```

---

## New Modules Summary

### Supertester.TelemetryHelpers

Provides async-safe telemetry testing by filtering events to only those matching the current test's context.

**Key Functions**:
- `attach_isolated/2` - Attach handler that only receives events with matching test_id
- `assert_telemetry/3` - Pattern-match assertion with automatic test_id filtering
- `refute_telemetry/3` - Negative assertion
- `flush_telemetry/1` - Clear stale events from mailbox
- `with_telemetry/3` - Scoped telemetry capture

### Supertester.LoggerIsolation

Provides per-process Logger level management without global side effects.

**Key Functions**:
- `isolate_level/1` - Set Logger level for current process only
- `capture_isolated/2` - capture_log with automatic level isolation
- `with_level/2` - Scoped level change
- `restore_level/0` - Explicit restoration

### Supertester.ETSIsolation

Provides per-test ETS table management, including table mirroring and scoped access.

**Key Functions**:
- `create_isolated/2` - Create test-scoped ETS table
- `mirror_table/2` - Create isolated copy of existing table
- `with_table/3` - Scoped table access with automatic cleanup
- `inject_table/3` - Replace module's table reference for duration of test

---

## IsolationContext Extensions

The `Supertester.IsolationContext` struct is extended with new fields:

```elixir
defstruct [
  # Existing fields...
  test_id: nil,
  registry: nil,
  processes: [],
  ets_tables: [],
  cleanup_callbacks: [],
  initial_processes: [],
  initial_ets_tables: [],
  tags: %{},

  # NEW in v0.4.0
  telemetry_handlers: [],        # [{handler_id, events}, ...]
  telemetry_test_id: nil,        # Unique ID for telemetry filtering
  logger_original_level: nil,    # Original process Logger level
  logger_isolated?: false,       # Whether Logger isolation is active
  isolated_ets_tables: %{},      # %{original_name => isolated_name}
  ets_mirrors: []                # [{source, mirror}, ...]
]
```

---

## ExUnitFoundation Integration

New options for `use Supertester.ExUnitFoundation`:

```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,

  # NEW in v0.4.0
  telemetry_isolation: true,     # Enable automatic telemetry filtering
  logger_isolation: true,        # Enable per-process Logger levels
  ets_isolation: []              # List of tables to auto-mirror: [:myapp_cache, :myapp_sessions]
```

---

## Telemetry Event Additions

New telemetry events emitted by isolation modules:

```elixir
# TelemetryHelpers
[:supertester, :telemetry, :handler, :attached]
[:supertester, :telemetry, :handler, :detached]
[:supertester, :telemetry, :event, :filtered]   # Event didn't match test_id
[:supertester, :telemetry, :event, :delivered]  # Event matched and delivered

# LoggerIsolation
[:supertester, :logger, :level, :isolated]
[:supertester, :logger, :level, :restored]

# ETSIsolation
[:supertester, :ets, :table, :created]
[:supertester, :ets, :table, :mirrored]
[:supertester, :ets, :table, :deleted]
```

---

## Dependencies

No new dependencies required. All features use Erlang/OTP and Elixir stdlib:

- `:telemetry` (existing) - For telemetry testing
- `Logger` (stdlib) - For per-process level management
- `:ets` (OTP) - For table management

---

## File Structure

```
lib/supertester/
├── telemetry_helpers.ex      # NEW
├── logger_isolation.ex       # NEW
├── ets_isolation.ex          # NEW
├── isolation_context.ex      # MODIFIED (extended struct)
├── ex_unit_foundation.ex     # MODIFIED (new options)
├── unified_test_foundation.ex # MODIFIED (new setup phases)
└── ... (existing files unchanged)
```

---

## Document Index

| Document | Description |
|----------|-------------|
| [01-telemetry-helpers.md](./01-telemetry-helpers.md) | Complete TelemetryHelpers specification |
| [02-logger-isolation.md](./02-logger-isolation.md) | Complete LoggerIsolation specification |
| [03-ets-isolation.md](./03-ets-isolation.md) | Complete ETSIsolation specification |
| [04-integration.md](./04-integration.md) | Module integration and composition |
| [05-migration-guide.md](./05-migration-guide.md) | Migration from v0.3.1 |
| [06-api-reference.md](./06-api-reference.md) | Complete API reference |

---

## Success Criteria

v0.4.0 is complete when:

1. All three modules implemented with full test coverage
2. Zero test flakiness in 1000 consecutive `mix test` runs
3. All existing tests pass without modification
4. Documentation complete with examples
5. CHANGELOG updated with migration notes
