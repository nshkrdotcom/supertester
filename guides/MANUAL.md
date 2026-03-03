# Supertester User Manual

Version: 0.6.0  
Last Updated: March 3, 2026

## Overview

Supertester is a deterministic OTP testing toolkit for Elixir. It focuses on:

- async-safe test isolation
- cast/call synchronization without timing sleeps
- supervisor strategy and tree verification
- chaos and performance diagnostics
- OTP-aware assertions

## Recommended Setup

Use the ExUnit adapter in test modules:

```elixir
defmodule MyApp.SomeTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
end
```

Isolation modes:

- `:basic`
- `:registry`
- `:full_isolation`
- `:contamination_detection` (runs sync)

Optional adapter features:

- `telemetry_isolation: true`
- `logger_isolation: true`
- `ets_isolation: [:named_table, ...]`
- tags: `@tag telemetry_events: [...]`, `@tag logger_level: :debug`, `@tag ets_tables: [...]`

## Core Workflow

### 1) Start isolated OTP subjects

```elixir
import Supertester.OTPHelpers

{:ok, server} = setup_isolated_genserver(MyServer)
{:ok, sup} = setup_isolated_supervisor(MySupervisor)
```

### 2) Replace sleeps with synchronization

```elixir
import Supertester.GenServerHelpers

:ok = cast_and_sync(server, :do_work)
```

`cast_and_sync/4` semantics:

- strict mode (`strict?: true`) raises `ArgumentError` if sync handling is missing.
- non-strict mode returns `{:error, :missing_sync_handler}` if missing.
- handled sync replies are returned as `{:ok, reply}`.

### 3) Assert OTP behavior

```elixir
import Supertester.Assertions

assert_genserver_state(server, fn s -> s.ready end)
assert_genserver_responsive(server)
assert_all_children_alive(sup)
```

### 4) Verify supervisor strategies

```elixir
import Supertester.SupervisorHelpers

result = test_restart_strategy(sup, :one_for_one, {:kill_child, :worker_1})
```

Behavior:

- raises on strategy mismatch.
- raises when scenario child IDs are missing.
- removed temporary children are not reported as restarted.

### 5) Add resilience testing

```elixir
import Supertester.ChaosHelpers

report = chaos_kill_children(sup, kill_rate: 0.4, duration_ms: 1_000)
```

Behavior:

- accepts pid and registered names (`:local`, `{:global, _}`, `{:via, _, _}`).
- `restarted` tracks observed child replacements, including cascade replacements.
- returns a report even if supervisor dies (`supervisor_crashed: true`).

### 6) Run suites with deadlines

```elixir
report = run_chaos_suite(sup, scenarios, timeout: 5_000)
```

Behavior:

- enforces a suite-level deadline.
- timed-out execution is reported as `:timeout` and remaining scenarios as `:suite_timeout`.
- scenario results that happen to be `{:error, :timeout}` are treated as ordinary failures, not suite cutoffs.

### 7) Leak and performance checks

```elixir
import Supertester.{Assertions, PerformanceHelpers}

assert_no_process_leaks(fn ->
  {:ok, pid} = Agent.start_link(fn -> :ok end)
  Agent.stop(pid)
end)

assert_performance(fn -> heavy_call() end, max_time_ms: 100)
```

Leak behavior:

- attributes leaks to spawned/linked process trees from the operation.
- catches delayed descendants.
- ignores short-lived transient processes.

## Safety Notes

- library code avoids unbounded dynamic atom creation for test IDs and isolation naming.
- ETS fallback injection requires existing env keys and refuses dynamic atom creation.

## Public Modules

- `Supertester`
- `Supertester.ExUnitFoundation`
- `Supertester.UnifiedTestFoundation`
- `Supertester.OTPHelpers`
- `Supertester.GenServerHelpers`
- `Supertester.SupervisorHelpers`
- `Supertester.ChaosHelpers`
- `Supertester.PerformanceHelpers`
- `Supertester.Assertions`
- `Supertester.ConcurrentHarness`
- `Supertester.PropertyHelpers`
- `Supertester.MessageHarness`
- `Supertester.Telemetry`
- `Supertester.TelemetryHelpers`
- `Supertester.LoggerIsolation`
- `Supertester.ETSIsolation`

## Additional References

- [API Guide](API_GUIDE.md)
- [Quick Start](QUICK_START.md)
- [Docs Index](DOCS_INDEX.md)
