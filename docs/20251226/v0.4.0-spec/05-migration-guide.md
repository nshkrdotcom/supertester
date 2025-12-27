# Migration Guide: v0.3.1 to v0.4.0

## Overview

Supertester v0.4.0 is a **fully backward-compatible** release. All existing tests continue to work without modification. This guide covers:

1. How to opt-in to new isolation features
2. Common migration patterns for flaky tests
3. Gradual adoption strategies

---

## Quick Start

### Minimal Change (Opt-In)

Add new options to your existing `use Supertester.ExUnitFoundation`:

```elixir
# Before (v0.3.1)
use Supertester.ExUnitFoundation, isolation: :full_isolation

# After (v0.4.0) - Add desired isolation features
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  telemetry_isolation: true,    # NEW
  logger_isolation: true,       # NEW
  ets_isolation: [:myapp_cache] # NEW
```

### Standalone Usage

Use new modules independently without ExUnitFoundation:

```elixir
use ExUnit.Case, async: true

alias Supertester.{TelemetryHelpers, LoggerIsolation, ETSIsolation}

setup do
  TelemetryHelpers.setup_telemetry_isolation()
  LoggerIsolation.setup_logger_isolation()
  ETSIsolation.setup_ets_isolation()
  :ok
end
```

---

## Migration Patterns

### Pattern 1: Telemetry Cross-Talk

#### Symptom

Tests intermittently fail with wrong telemetry metadata:

```
Assertion with == failed
code:  assert metadata.request_id == "req-expired"
left:  "test-request-id"
right: "req-expired"
```

#### Before (Flaky)

```elixir
test "emits telemetry on error" do
  handler_id = "test-#{System.unique_integer()}"
  :telemetry.attach(handler_id, [:myapp, :error], &send_to_self/4, self())
  on_exit(fn -> :telemetry.detach(handler_id) end)

  MyApp.Service.fail()

  # FLAKY: May receive events from concurrent tests
  assert_receive {:telemetry, [:myapp, :error], _, %{code: "expected"}}
end
```

#### After (Robust)

```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  telemetry_isolation: true

test "emits telemetry on error" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :error])

  MyApp.Service.fail()

  # Only receives events from THIS test
  TelemetryHelpers.assert_telemetry([:myapp, :error], %{code: "expected"})
end
```

#### Application Code Change (Optional but Recommended)

For telemetry isolation to work automatically, application code should propagate test context:

```elixir
# In your application's telemetry module
defmodule MyApp.Telemetry do
  def emit(event, measurements, metadata) do
    # Automatically include test context when running tests
    enriched = case Process.get(:supertester_telemetry_test_id) do
      nil -> metadata
      id -> Map.put(metadata, :supertester_test_id, id)
    end

    :telemetry.execute(event, measurements, enriched)
  end
end
```

---

### Pattern 2: Logger Level Contamination

#### Symptom

Log capture misses expected messages or captures unexpected ones:

```
Assertion with =~ failed
code:  assert log =~ "[REDACTED]"
left:  "\e[22m\n14:52:43.190 [info] training loop completed\n\e[0m"
right: "[REDACTED]"
```

#### Before (Flaky)

```elixir
test "logs debug info" do
  previous = Logger.level()

  log = capture_log([level: :debug], fn ->
    Logger.configure(level: :debug)  # GLOBAL! Affects all tests
    MyApp.Service.work()
  end)

  Logger.configure(level: previous)  # Race condition if test fails
  assert log =~ "debug message"
end
```

#### After (Robust)

```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  logger_isolation: true

test "logs debug info" do
  log = LoggerIsolation.capture_isolated!(:debug, fn ->
    MyApp.Service.work()
  end)

  assert log =~ "debug message"
  # Level automatically restored, no global contamination
end
```

#### Alternative: Tag-Based

```elixir
@tag logger_level: :debug
test "logs debug info" do
  # Level automatically set for this test only
  log = capture_log(fn ->
    MyApp.Service.work()
  end)

  assert log =~ "debug message"
end
```

---

### Pattern 3: ETS Table State Leakage

#### Symptom

Tests fail with missing or corrupted data:

```
** (MatchError) no match of right hand side value: []
```

Or Agent/GenServer crashes:

```
** (exit) exited in: GenServer.stop(#PID<0.852.0>, :normal, :infinity)
    ** (EXIT) shutdown
```

#### Before (Flaky)

```elixir
setup do
  :ets.delete_all_objects(:myapp_cache)  # Nukes concurrent tests!
  :ok
end

test "caches values" do
  MyApp.Cache.put(:key, :value)
  assert MyApp.Cache.get(:key) == :value  # FLAKY!
end
```

#### After (Robust)

```elixir
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  ets_isolation: [:myapp_cache]

test "caches values", %{isolation_context: ctx} do
  cache = ctx.isolated_ets_tables[:myapp_cache]

  # Use isolated cache directly
  :ets.insert(cache, {:key, :value})
  assert :ets.lookup(cache, :key) == [{:key, :value}]

  # Original :myapp_cache untouched
end
```

#### Alternative: Inject into Module

If your module hardcodes the table name:

```elixir
setup do
  {:ok, _} = ETSIsolation.inject_table(MyApp.Cache, :table_name, :test_cache)
  :ok
end

test "caches values" do
  # MyApp.Cache now uses :test_cache
  MyApp.Cache.put(:key, :value)
  assert MyApp.Cache.get(:key) == :value
end
```

---

### Pattern 4: Agent Cleanup Race

#### Symptom

Intermittent cleanup failures:

```
** (exit) exited in: GenServer.stop(#PID<0.852.0>, :normal, :infinity)
    ** (EXIT) exited in: :sys.terminate(...)
        ** (EXIT) shutdown
```

#### Before (Flaky)

```elixir
setup do
  {:ok, counter} = Agent.start_link(fn -> 0 end)

  on_exit(fn ->
    if Process.alive?(counter) do
      Agent.stop(counter)  # Race with linked process termination
    end
  end)

  {:ok, counter: counter}
end
```

#### After (Robust)

```elixir
setup do
  # start_supervised! handles cleanup automatically and correctly
  counter = start_supervised!({Agent, fn -> 0 end})
  {:ok, counter: counter}
end
```

Or with Supertester helpers:

```elixir
setup do
  {:ok, counter} = OTPHelpers.setup_isolated_genserver(Agent, "counter",
    init_arg: fn -> 0 end
  )
  {:ok, counter: counter}
end
```

---

## Gradual Adoption Strategy

### Phase 1: Enable for Flaky Tests

Start by adding isolation to tests that are currently flaky:

```elixir
# In flaky test file
use Supertester.ExUnitFoundation,
  isolation: :full_isolation,
  telemetry_isolation: true,
  logger_isolation: true
```

### Phase 2: Enable for Test Modules with Global State

Identify modules that interact with shared state and enable relevant isolation:

```elixir
# Tests that use Logger.configure
use Supertester.ExUnitFoundation,
  logger_isolation: true

# Tests that attach telemetry handlers
use Supertester.ExUnitFoundation,
  telemetry_isolation: true

# Tests that access named ETS tables
use Supertester.ExUnitFoundation,
  ets_isolation: [:table1, :table2]
```

### Phase 3: Create Base Test Case Module

Standardize isolation across your project:

```elixir
defmodule MyApp.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation,
        isolation: :full_isolation,
        telemetry_isolation: true,
        logger_isolation: true,
        ets_isolation: Application.compile_env(:myapp, :test_ets_tables, [])
    end
  end
end

# In config/test.exs
config :myapp, test_ets_tables: [:myapp_cache, :myapp_sessions]

# In tests
defmodule MyApp.SomeTest do
  use MyApp.TestCase
  # All isolation enabled automatically
end
```

### Phase 4: Enable Project-Wide

Once stable, enable isolation by default:

```elixir
# In test_helper.exs
Application.put_env(:supertester, :default_isolation, [
  isolation: :full_isolation,
  telemetry_isolation: true,
  logger_isolation: true
])
```

---

## Breaking Changes

**None.** v0.4.0 is fully backward compatible.

### Behavioral Notes

1. **New process dictionary keys**: The new modules use process dictionary keys prefixed with `:supertester_`. Avoid using these prefixes in your own code.

2. **New telemetry events**: The modules emit telemetry under `[:supertester, ...]`. If you're listening to all Supertester telemetry, you'll receive new events.

3. **IsolationContext struct extended**: The struct has new fields. Code that pattern-matches on the entire struct needs updating:

   ```elixir
   # Before (will still work but misses new fields)
   %IsolationContext{test_id: id} = ctx

   # After (explicit about what you're matching)
   %IsolationContext{test_id: id} = ctx
   # OR use accessor functions
   id = ctx.test_id
   ```

---

## Verification Checklist

After migration, run these checks:

### 1. Run Full Test Suite Multiple Times

```bash
for i in {1..20}; do
  echo "Run $i"
  mix test --seed random || echo "FAILED on run $i"
done
```

### 2. Check for Leaked State

```elixir
# Add to test_helper.exs temporarily
ExUnit.after_suite(fn _ ->
  # Check for leaked ETS tables
  tables = :ets.all()
  supertester_tables = Enum.filter(tables, fn t ->
    name = :ets.info(t, :name)
    is_atom(name) and String.starts_with?(Atom.to_string(name), "supertester")
  end)

  if supertester_tables != [] do
    IO.warn("Leaked Supertester ETS tables: #{inspect(supertester_tables)}")
  end

  # Check for leaked telemetry handlers
  handlers = :telemetry.list_handlers([])
  supertester_handlers = Enum.filter(handlers, fn h ->
    String.starts_with?(h.id, "supertester")
  end)

  if supertester_handlers != [] do
    IO.warn("Leaked Supertester telemetry handlers: #{inspect(supertester_handlers)}")
  end
end)
```

### 3. Measure Performance

```bash
# Before migration
mix test 2>&1 | tail -1  # Note "Finished in X.X seconds"

# After migration
mix test 2>&1 | tail -1  # Should be similar or faster (more async)
```

---

## Troubleshooting

### "Telemetry isolation not set up"

```
** (RuntimeError) Telemetry isolation not set up. Call setup_telemetry_isolation/0 first.
```

**Fix**: Add `telemetry_isolation: true` to your ExUnitFoundation options, or call `TelemetryHelpers.setup_telemetry_isolation()` in setup.

### "Logger isolation not set up"

```
** (ArgumentError) Logger isolation not set up for this process.
```

**Fix**: Add `logger_isolation: true` to your ExUnitFoundation options, or call `LoggerIsolation.setup_logger_isolation()` in setup.

### "ETS isolation not set up"

```
** (RuntimeError) ETS isolation not set up. Call setup_ets_isolation/0 first.
```

**Fix**: Add `ets_isolation: [...]` to your ExUnitFoundation options, or call `ETSIsolation.setup_ets_isolation()` in setup.

### Telemetry Events Not Received

If `assert_telemetry` times out, ensure:

1. Application code includes test context in telemetry metadata
2. The event name matches exactly (list of atoms)
3. The correct handler was attached before the operation

### ETS Table Not Found

```
{:error, {:table_not_found, :my_table}}
```

Ensure the table exists before mirroring. Tables created by application startup should exist; tables created per-request may not.

---

## Getting Help

- GitHub Issues: [supertester issues](https://github.com/...)
- Documentation: See other files in this spec directory
- Examples: See `test/supertester/*_test.exs` for usage patterns
