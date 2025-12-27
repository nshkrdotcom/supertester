# Supertester.LoggerIsolation Specification

## Module Purpose

Provide per-process Logger level management that doesn't affect other concurrent tests, eliminating flakiness caused by global `Logger.configure/1` calls.

---

## The Problem in Detail

### Logger.configure/1 is Global

When a test calls `Logger.configure(level: :debug)`, it affects **all processes in the VM**:

```elixir
# Test A
test "logs debug messages" do
  Logger.configure(level: :debug)  # Affects entire VM!

  log = capture_log(fn ->
    Logger.debug("debug message")
  end)

  assert log =~ "debug message"
  Logger.configure(level: :info)  # Restore... but race condition exists
end

# Test B (running concurrently)
test "only logs warnings" do
  log = capture_log([level: :warning], fn ->
    Logger.warning("warning")
    Logger.debug("should not appear")  # But it DOES because Test A set :debug!
  end)

  refute log =~ "should not appear"  # FLAKY! Depends on timing
end
```

### capture_log's level Option is Insufficient

While `capture_log([level: :debug], fn -> ... end)` sets the capture level, it doesn't prevent other tests from changing the global level during capture:

```elixir
capture_log([level: :debug], fn ->
  # During this execution window, another test could call:
  # Logger.configure(level: :error)
  # which would cause debug messages to not be generated at all
  Logger.debug("might not be logged")
end)
```

### Logger.put_process_level/2 Exists But Has Caveats

Elixir provides `Logger.put_process_level/2` for per-process levels, but:

1. Requires manual cleanup via `Logger.delete_process_level/1`
2. Easy to forget cleanup, leading to level accumulation
3. Not integrated with ExUnit lifecycle

---

## Solution: Managed Process-Level Isolation

### Core Concept

Wrap `Logger.put_process_level/2` with automatic lifecycle management and ExUnit integration.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Test Process                             │
│  Original level: nil (inherits global)                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    isolate_level(:debug)                         │
│  Logger.put_process_level(self(), :debug)                       │
│  Registers on_exit cleanup                                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Test Execution                                │
│  Logger respects process-specific level                          │
│  Other tests unaffected                                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    on_exit callback                              │
│  Logger.delete_process_level(self())                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## API Specification

### Types

```elixir
@type level :: :emergency | :alert | :critical | :error | :warning | :notice | :info | :debug
@type level_or_all :: level() | :all | :none

@type isolate_opts :: [
  cleanup: boolean()    # Register automatic cleanup (default: true)
]

@type capture_opts :: [
  level: level(),       # Minimum level to capture (default: :debug)
  colors: boolean(),    # Include ANSI colors (default: false)
  format: String.t(),   # Log format string
  metadata: [atom()]    # Metadata keys to include
]
```

### Core Functions

#### `setup_logger_isolation/0`

Initialize logger isolation for the current test. Called automatically by ExUnitFoundation when `logger_isolation: true`.

```elixir
@spec setup_logger_isolation() :: :ok
@spec setup_logger_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}

def setup_logger_isolation do
  # Record original state for restoration
  original_level = Logger.get_process_level(self())
  Process.put(:supertester_logger_original_level, original_level)
  Process.put(:supertester_logger_isolated, true)

  Supertester.Env.on_exit(fn ->
    restore_level()
  end)

  emit_setup()
  :ok
end

def setup_logger_isolation(%IsolationContext{} = ctx) do
  :ok = setup_logger_isolation()
  original_level = Process.get(:supertester_logger_original_level)

  updated_ctx = %{ctx |
    logger_original_level: original_level,
    logger_isolated?: true
  }

  {:ok, updated_ctx}
end
```

#### `isolate_level/1`

Set the Logger level for the current process only.

```elixir
@spec isolate_level(level_or_all()) :: :ok
@spec isolate_level(level_or_all(), isolate_opts()) :: :ok

def isolate_level(level, opts \\ []) do
  ensure_isolation_setup!()

  Logger.put_process_level(self(), level)

  if Keyword.get(opts, :cleanup, true) and not cleanup_registered?() do
    Supertester.Env.on_exit(fn -> restore_level() end)
    Process.put(:supertester_logger_cleanup_registered, true)
  end

  emit_level_set(level)
  :ok
end

defp ensure_isolation_setup! do
  unless Process.get(:supertester_logger_isolated) do
    raise """
    Logger isolation not set up. Either:
    1. Use `use Supertester.ExUnitFoundation, logger_isolation: true`
    2. Call `LoggerIsolation.setup_logger_isolation/0` in your setup block
    """
  end
end
```

#### `restore_level/0`

Restore the process's Logger level to its original state.

```elixir
@spec restore_level() :: :ok

def restore_level do
  case Process.get(:supertester_logger_original_level) do
    nil ->
      Logger.delete_process_level(self())
    level ->
      Logger.put_process_level(self(), level)
  end

  Process.delete(:supertester_logger_isolated)
  Process.delete(:supertester_logger_original_level)
  Process.delete(:supertester_logger_cleanup_registered)

  emit_level_restored()
  :ok
end
```

#### `get_isolated_level/0`

Get the current process's isolated level.

```elixir
@spec get_isolated_level() :: level() | nil

def get_isolated_level do
  Logger.get_process_level(self())
end
```

#### `isolated?/0`

Check if logger isolation is active for the current process.

```elixir
@spec isolated?() :: boolean()

def isolated? do
  Process.get(:supertester_logger_isolated, false)
end
```

---

### Capture Functions

#### `capture_isolated/2`

Capture logs with automatic level isolation. Safe alternative to `capture_log` with global level changes.

```elixir
@spec capture_isolated(level(), (-> term())) :: {String.t(), term()}
@spec capture_isolated(level(), (-> term()), capture_opts()) :: {String.t(), term()}

def capture_isolated(level, fun, opts \\ []) do
  ensure_isolation_setup!()

  # Set process-level (not global) level
  previous_level = get_isolated_level()
  isolate_level(level, cleanup: false)

  try do
    # capture_log will now see the process-level setting
    log = ExUnit.CaptureLog.capture_log(opts, fun)
    result = fun.()
    {log, result}
  after
    # Restore to previous isolated level, not global
    if previous_level do
      isolate_level(previous_level, cleanup: false)
    else
      Logger.delete_process_level(self())
    end
  end
end
```

#### `capture_isolated!/2`

Same as `capture_isolated/2` but returns only the log string (for compatibility with capture_log patterns).

```elixir
@spec capture_isolated!(level(), (-> term())) :: String.t()
@spec capture_isolated!(level(), (-> term()), capture_opts()) :: String.t()

def capture_isolated!(level, fun, opts \\ []) do
  ensure_isolation_setup!()

  previous_level = get_isolated_level()
  isolate_level(level, cleanup: false)

  try do
    ExUnit.CaptureLog.capture_log(opts, fun)
  after
    if previous_level do
      isolate_level(previous_level, cleanup: false)
    else
      Logger.delete_process_level(self())
    end
  end
end
```

---

### Scoped Functions

#### `with_level/2`

Execute a function with a temporary Logger level, then restore.

```elixir
@spec with_level(level(), (-> result)) :: result when result: term()

def with_level(level, fun) do
  ensure_isolation_setup!()

  previous_level = get_isolated_level()
  isolate_level(level, cleanup: false)

  try do
    fun.()
  after
    if previous_level do
      isolate_level(previous_level, cleanup: false)
    else
      Logger.delete_process_level(self())
    end
  end
end
```

#### `with_level_and_capture/2`

Execute a function with a temporary Logger level and capture logs.

```elixir
@spec with_level_and_capture(level(), (-> result)) :: {String.t(), result} when result: term()

def with_level_and_capture(level, fun) do
  log = capture_isolated!(level, fun)
  result = fun.()
  {log, result}
end
```

---

### Tag-Based Integration

For declarative level setting via test tags:

```elixir
# In ExUnitFoundation, when logger_isolation: true
setup context do
  if level = context[:logger_level] do
    LoggerIsolation.isolate_level(level)
  end
  :ok
end
```

Usage:

```elixir
@tag logger_level: :debug
test "logs debug info" do
  log = ExUnit.CaptureLog.capture_log(fn ->
    Logger.debug("debug message")
  end)

  assert log =~ "debug message"
end
```

---

## Usage Examples

### Basic Usage

```elixir
defmodule MyApp.LoggingTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation,
    logger_isolation: true

  test "captures debug logs without affecting other tests" do
    # Set debug level for THIS process only
    LoggerIsolation.isolate_level(:debug)

    log = capture_log(fn ->
      Logger.debug("debug message")
      Logger.info("info message")
    end)

    assert log =~ "debug message"
    assert log =~ "info message"
  end

  test "concurrent test uses default level" do
    # This test runs concurrently, unaffected by above test's :debug setting
    log = capture_log(fn ->
      Logger.debug("should not appear at default level")
      Logger.info("should appear")
    end)

    # Debug won't appear because this process uses default level
    refute log =~ "should not appear"
    assert log =~ "should appear"
  end
end
```

### Using with_level/2

```elixir
test "temporarily uses error level" do
  # Default: process inherits global level

  result = LoggerIsolation.with_level(:error, fn ->
    Logger.warning("suppressed")
    Logger.error("visible")
    :done
  end)

  assert result == :done
  # After with_level, process returns to original level
end
```

### Using Tag-Based Level

```elixir
@tag logger_level: :debug
test "automatically sets debug level" do
  # Level was set in setup based on tag
  assert LoggerIsolation.get_isolated_level() == :debug

  log = capture_log(fn ->
    Logger.debug("visible due to tag")
  end)

  assert log =~ "visible"
end
```

### Capturing with Level

```elixir
test "captures only error and above" do
  log = LoggerIsolation.capture_isolated!(:error, fn ->
    Logger.debug("hidden")
    Logger.warning("hidden")
    Logger.error("visible")
  end)

  refute log =~ "hidden"
  assert log =~ "visible"
end
```

### Fixing the api_test.exs Pattern

Before (flaky):
```elixir
test "headers and redaction redacts secrets when dumping headers" do
  previous_level = Logger.level()

  log = capture_log([level: :debug], fn ->
    Logger.configure(level: :debug)  # GLOBAL CHANGE - FLAKY!
    assert {:ok, %{"ok" => true}} = API.get("/dump", config: config)
  end)

  Logger.configure(level: previous_level)
  assert log =~ "[REDACTED]"
end
```

After (robust):
```elixir
test "headers and redaction redacts secrets when dumping headers" do
  log = LoggerIsolation.capture_isolated!(:debug, fn ->
    assert {:ok, %{"ok" => true}} = API.get("/dump", config: config)
  end)

  assert log =~ "[REDACTED]"
end
```

---

## Implementation Details

### Process Dictionary Keys

```elixir
:supertester_logger_isolated          # boolean - isolation is active
:supertester_logger_original_level    # level | nil - level before isolation
:supertester_logger_cleanup_registered # boolean - cleanup registered
```

### Telemetry Events

```elixir
[:supertester, :logger, :isolation, :setup]
  measurements: %{}
  metadata: %{pid: pid()}

[:supertester, :logger, :level, :set]
  measurements: %{}
  metadata: %{pid: pid(), level: level()}

[:supertester, :logger, :level, :restored]
  measurements: %{}
  metadata: %{pid: pid()}
```

### Error Handling

```elixir
defp ensure_isolation_setup! do
  unless Process.get(:supertester_logger_isolated) do
    raise ArgumentError, """
    Logger isolation not set up for this process.

    To fix, either:
    1. Add `logger_isolation: true` to your ExUnitFoundation use:
       use Supertester.ExUnitFoundation, isolation: :full_isolation, logger_isolation: true

    2. Or call setup explicitly in your test setup:
       setup do
         Supertester.LoggerIsolation.setup_logger_isolation()
         :ok
       end
    """
  end
end
```

---

## Testing the Module Itself

```elixir
defmodule Supertester.LoggerIsolationTest do
  use ExUnit.Case, async: true

  alias Supertester.LoggerIsolation

  describe "isolate_level/1" do
    test "sets process-specific level" do
      LoggerIsolation.setup_logger_isolation()
      LoggerIsolation.isolate_level(:debug)

      assert Logger.get_process_level(self()) == :debug
    end

    test "doesn't affect other processes" do
      LoggerIsolation.setup_logger_isolation()
      LoggerIsolation.isolate_level(:debug)

      # Spawn another process and check its level
      parent = self()
      spawn(fn ->
        level = Logger.get_process_level(self())
        send(parent, {:other_level, level})
      end)

      assert_receive {:other_level, nil}  # nil means inherits global
    end
  end

  describe "restore_level/0" do
    test "removes process-specific level" do
      LoggerIsolation.setup_logger_isolation()
      LoggerIsolation.isolate_level(:debug)
      LoggerIsolation.restore_level()

      assert Logger.get_process_level(self()) == nil
    end
  end

  describe "with_level/2" do
    test "temporarily changes level" do
      LoggerIsolation.setup_logger_isolation()

      levels = []

      levels = [Logger.get_process_level(self()) | levels]

      result = LoggerIsolation.with_level(:error, fn ->
        levels = [Logger.get_process_level(self()) | levels]
        :ok
      end)

      levels = [Logger.get_process_level(self()) | levels]

      assert result == :ok
      # Level should be: nil -> :error -> nil
    end
  end

  describe "concurrent isolation" do
    test "parallel tests have independent levels" do
      tasks = for level <- [:debug, :info, :warning, :error] do
        Task.async(fn ->
          LoggerIsolation.setup_logger_isolation()
          LoggerIsolation.isolate_level(level)
          Process.sleep(10)  # Simulate work
          {level, Logger.get_process_level(self())}
        end)
      end

      results = Task.await_many(tasks)

      for {expected, actual} <- results do
        assert expected == actual
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

  # Logger isolation state
  logger_original_level: nil,    # Original level before isolation
  logger_isolated?: false        # Whether isolation is active
]
```

When using ExUnitFoundation with `logger_isolation: true`:

```elixir
# In ex_unit_foundation.ex
setup context do
  ctx = context[:isolation_context] || %IsolationContext{}

  ctx = if @logger_isolation do
    {:ok, ctx} = LoggerIsolation.setup_logger_isolation(ctx)
    ctx
  else
    ctx
  end

  # Handle tag-based level setting
  ctx = if level = context[:logger_level] do
    LoggerIsolation.isolate_level(level)
    ctx
  else
    ctx
  end

  {:ok, isolation_context: ctx}
end
```

---

## Migration Notes

### From Logger.configure/1

Before:
```elixir
test "logs debug" do
  previous = Logger.level()
  Logger.configure(level: :debug)

  # ... test ...

  Logger.configure(level: previous)
end
```

After:
```elixir
test "logs debug" do
  LoggerIsolation.isolate_level(:debug)
  # ... test ...
  # Automatic cleanup via on_exit
end
```

### From capture_log with Manual Level

Before:
```elixir
test "captures debug" do
  log = capture_log([level: :debug], fn ->
    Logger.configure(level: :debug)  # Needed because capture_log level != Logger level
    Logger.debug("message")
  end)
end
```

After:
```elixir
test "captures debug" do
  log = LoggerIsolation.capture_isolated!(:debug, fn ->
    Logger.debug("message")
  end)
end
```

### With Tag-Based Setup

Before:
```elixir
setup do
  Logger.configure(level: :debug)
  on_exit(fn -> Logger.configure(level: :info) end)
  :ok
end
```

After:
```elixir
@tag logger_level: :debug
test "uses debug level" do
  # Level automatically set and cleaned up
end
```
