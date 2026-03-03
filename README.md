# Supertester

<p align="center">
  <img src="assets/supertester-logo.svg" alt="Supertester Logo" width="200">
</p>

<p align="center">
  <a href="https://hex.pm/packages/supertester"><img alt="Hex.pm" src="https://img.shields.io/hexpm/v/supertester.svg"></a>
  <a href="https://hexdocs.pm/supertester"><img alt="Documentation" src="https://img.shields.io/badge/docs-hexdocs-purple.svg"></a>
  <a href="https://github.com/nshkrdotcom/supertester/actions"><img alt="Build Status" src="https://img.shields.io/github/actions/workflow/status/nshkrdotcom/supertester/ci.yml"></a>
  <a href="https://opensource.org/licenses/MIT"><img alt="License" src="https://img.shields.io/hexpm/l/supertester.svg"></a>
</p>

Supertester is an OTP-focused testing toolkit for Elixir. It helps you write deterministic tests for concurrent systems without `Process.sleep/1`, with isolation for async test execution and tooling for supervisors, chaos, and performance.

Version: `0.6.0`

## What It Solves

- Flaky tests caused by race conditions and timing guesses.
- Name collisions when running OTP tests with `async: true`.
- Low-confidence supervision and crash-recovery tests.
- Missing visibility into concurrency, mailbox, chaos, and performance behavior.

## Installation

Add Supertester as a test dependency:

```elixir
def deps do
  [
    {:supertester, "~> 0.6.0", only: :test}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Example

### Before: timing-based and non-parallel-friendly

```elixir
defmodule MyApp.CounterTest do
  use ExUnit.Case, async: false

  test "increment" do
    {:ok, _pid} = start_supervised({Counter, name: Counter})

    GenServer.cast(Counter, :increment)
    Process.sleep(50)

    assert GenServer.call(Counter, :state).count == 1
  end
end
```

### After: isolated and deterministic

```elixir
defmodule MyApp.CounterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  test "increment" do
    {:ok, counter} = setup_isolated_genserver(Counter)

    :ok = cast_and_sync(counter, :increment)

    assert_genserver_state(counter, fn state -> state.count == 1 end)
  end
end
```

## Core Capabilities

- `Supertester.ExUnitFoundation`: ExUnit adapter that wires isolation setup and async behavior.
- `Supertester.UnifiedTestFoundation`: isolation runtime for custom harnesses.
- `Supertester.TestableGenServer`: injects `:__supertester_sync__` handler for deterministic cast testing.
- `Supertester.OTPHelpers`: isolated process/supervisor startup with cleanup.
- `Supertester.GenServerHelpers`: `cast_and_sync/4`, state access, concurrent/stress helpers.
- `Supertester.SupervisorHelpers`: restart strategy and tree structure validation.
- `Supertester.ChaosHelpers`: crash injection, kill-children chaos, suite execution with deadline.
- `Supertester.PerformanceHelpers`: performance bounds, mailbox growth, leak checks.
- `Supertester.Assertions`: OTP-aware assertions for process, server, and supervisor behavior.
- `Supertester.ConcurrentHarness`: declarative multithreaded scenario runner.
- `Supertester.PropertyHelpers`: StreamData generators for concurrent scenarios.
- `Supertester.MessageHarness`: mailbox tracing helpers.
- `Supertester.Telemetry`: normalized `:telemetry` events under `[:supertester | ...]`.
- `Supertester.TelemetryHelpers`, `LoggerIsolation`, `ETSIsolation`: per-test observability and state isolation extensions.

## Behavior Notes

- `cast_and_sync/4` with `strict?: true` raises on missing sync handler.
- In non-strict mode, missing sync handlers return `{:error, :missing_sync_handler}` (never `:ok`).
- `test_restart_strategy/3` validates expected strategy and raises on mismatch.
- `assert_supervision_tree_structure/2` validates `:supervisor`, `:strategy`, and expected child modules.
- `run_chaos_suite/3` enforces a suite-wide timeout (`:timeout` / `:suite_timeout` failure reasons).

## Reliability and Safety Improvements

Recent hardening changes include:

- Atom-safe isolation and helper naming (no unbounded dynamic atom creation for test identifiers/process naming paths).
- ETS table injection fallback no longer creates dynamic atoms at runtime.
- More accurate chaos restart accounting (`restarted` is observed, not assumed).
- Stronger leak detection focused on processes spawned or linked by the operation under test.

## Documentation

- [Documentation Index](guides/DOCS_INDEX.md)
- [Quick Start](guides/QUICK_START.md)
- [User Manual](guides/MANUAL.md)
- [API Guide](guides/API_GUIDE.md)
- [Changelog](CHANGELOG.md)

## Examples

- [Examples Index](examples/README.md)
- [EchoLab Example App](examples/echo_lab/README.md)

## Contributing

Contributions are welcome. Please include tests for behavior changes and keep docs aligned with API updates.

## License

MIT
