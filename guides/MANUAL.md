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

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:supertester, "~> 0.6.0", only: :test}
  ]
end
```

Then run `mix deps.get`.

## Prerequisites

### TestableGenServer

Most Supertester workflows revolve around `cast_and_sync/4`, which sends a cast and then makes a synchronizing call to ensure the cast was processed. For this to work, your GenServer must handle the sync message.

Add `use Supertester.TestableGenServer` after `use GenServer`:

```elixir
defmodule MyApp.Counter do
  use GenServer
  use Supertester.TestableGenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{count: 0}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:increment, state) do
    {:noreply, %{state | count: state.count + 1}}
  end
end
```

This injects a `handle_call(:__supertester_sync__, ...)` clause that replies `:ok`. It also supports `{:__supertester_sync__, return_state: true}` which replies with `{:ok, state}`.

## Recommended Setup

Use the ExUnit adapter in test modules:

```elixir
defmodule MyApp.SomeTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
end
```

Isolation modes:

- `:basic` — minimal tracking, no registry
- `:registry` — shared Registry for process naming
- `:full_isolation` — full process/ETS tracking with cleanup
- `:contamination_detection` — compares before/after state (runs sync)

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

These helpers generate unique process names (using `{:via, Registry, ...}` tuples) so concurrent async tests never collide. Processes are tracked and cleaned up automatically when the test exits.

### 2) Replace sleeps with synchronization

```elixir
import Supertester.GenServerHelpers

:ok = cast_and_sync(server, :do_work)
```

`cast_and_sync/4` semantics:

- When the sync handler replies `:ok` (the default `TestableGenServer` behavior), returns bare `:ok`.
- When the sync handler replies with any other value, returns `{:ok, reply}`.
- strict mode (`strict?: true`) raises `ArgumentError` if sync handling is missing.
- non-strict mode returns `{:error, :missing_sync_handler}` if missing.

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
assert :worker_1 in result.restarted
```

Behavior:

- validates expected strategy at runtime and raises on mismatch.
- raises when scenario child IDs are missing.
- removed temporary children are not reported as restarted.

### 5) Add resilience testing

```elixir
import Supertester.ChaosHelpers

report = chaos_kill_children(sup, kill_rate: 0.4, duration_ms: 1_000)
```

Behavior:

- accepts pid and registered names (atom, `{:global, _}`, `{:via, _, _}`).
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
- propagates exceptions from the operation (no false leak reports on raise).

## Custom Harness Integration (Supertester.Env)

Supertester delegates cleanup registration to `Supertester.Env`, which defaults to `ExUnit.Callbacks.on_exit/1`. To integrate with a custom test runner:

1. Implement the `Supertester.Env` behaviour:

```elixir
defmodule MyHarness.TestEnv do
  @behaviour Supertester.Env

  @impl true
  def on_exit(callback) when is_function(callback, 0) do
    MyHarness.register_cleanup(callback)
  end
end
```

2. Configure it in your test config:

```elixir
# config/test.exs
config :supertester, env_module: MyHarness.TestEnv
```

The `on_exit/1` callback receives a zero-arity function that must be called when the test finishes to clean up isolated processes, ETS tables, and other resources.

## Safety Notes

- Library code avoids unbounded dynamic atom creation for test IDs and isolation naming.
- Process names use `{:via, Registry, ...}` tuples instead of dynamic atoms.
- ETS fallback injection requires existing env keys and refuses dynamic atom creation.

## Common Patterns

### Deterministic GenServer test

```elixir
defmodule MyApp.CounterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  test "increments deterministically" do
    {:ok, counter} = setup_isolated_genserver(Counter)
    :ok = cast_and_sync(counter, :increment)
    assert_genserver_state(counter, fn state -> state.count == 1 end)
  end
end
```

### Verify supervisor tree structure

```elixir
assert_supervision_tree_structure(sup, %{
  supervisor: MySupervisor,
  strategy: :one_for_one,
  children: [
    {:worker_1, MyWorker},
    {:worker_2, MyWorker}
  ]
})
```

### Chaos resilience assertion

```elixir
assert_chaos_resilient(
  sup,
  fn -> chaos_kill_children(sup, kill_rate: 0.5, duration_ms: 200) end,
  fn -> length(Supervisor.which_children(sup)) == expected_count end,
  timeout: 2_000
)
```

## Troubleshooting

### "no handle_call/3 clause was provided" or missing sync handler errors

Your GenServer does not handle `:__supertester_sync__`. Add `use Supertester.TestableGenServer` to your module.

### Tests fail with `{:error, :noproc}`

The GenServer has crashed or been stopped before your assertion. Check for unhandled messages or invalid state transitions.

### Tests pass individually but fail when run together

You may be using named processes without isolation. Use `setup_isolated_genserver/3` which generates unique names, or use `Supertester.ExUnitFoundation` with `:full_isolation`.

### `{:error, :missing_sync_handler}` from `cast_and_sync`

The server is missing a sync handler. Either add `use Supertester.TestableGenServer` to the server module, or implement a `handle_call(:__supertester_sync__, ...)` clause manually.

## Public Modules

- `Supertester`
- `Supertester.ExUnitFoundation`
- `Supertester.UnifiedTestFoundation`
- `Supertester.TestableGenServer`
- `Supertester.Env`
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
