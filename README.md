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

Supertester is an OTP-focused testing toolkit for Elixir. It helps you write deterministic tests for concurrent systems without `Process.sleep/1`, while keeping tests async-safe through per-test isolation.

Version: `0.6.0`

## Installation

```elixir
def deps do
  [
    {:supertester, "~> 0.6.0", only: :test}
  ]
end
```

```bash
mix deps.get
```

## Quick Example

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

## Core Modules

- `Supertester.ExUnitFoundation` - ExUnit adapter with isolation wiring.
- `Supertester.UnifiedTestFoundation` - isolation runtime for custom harnesses.
- `Supertester.TestableGenServer` - injects `:__supertester_sync__` handlers.
- `Supertester.OTPHelpers` - isolated startup/teardown helpers.
- `Supertester.GenServerHelpers` - call/cast sync helpers and GenServer stress tools.
- `Supertester.SupervisorHelpers` - restart strategy and tree assertions.
- `Supertester.ChaosHelpers` - crash injection, supervisor chaos, suite runner.
- `Supertester.PerformanceHelpers` - time/memory/reduction assertions.
- `Supertester.Assertions` - OTP-aware process/supervisor assertions.
- `Supertester.ConcurrentHarness` - declarative multi-thread scenario runner.
- `Supertester.PropertyHelpers` - StreamData generators for scenarios.
- `Supertester.MessageHarness` - mailbox tracing for diagnostics.
- `Supertester.Telemetry`, `TelemetryHelpers`, `LoggerIsolation`, `ETSIsolation`.

## Behavioral Notes

- `cast_and_sync/4`
  - `strict?: true` raises `ArgumentError` when synchronization support is missing.
  - Non-strict mode returns `{:error, :missing_sync_handler}` when missing.
  - Explicit sync replies (including error tuples) return `{:ok, reply}`.
- `test_restart_strategy/3`
  - validates expected supervisor strategy and raises on mismatch.
  - raises `ArgumentError` when scenario child IDs are unknown.
  - temporary removed children are not reported as restarted.
- `chaos_kill_children/2`
  - accepts pid or registered supervisor name (`:local`, `{:global, _}`, `{:via, _, _}`).
  - `restarted` counts observed child replacements, including cascade replacements.
- `run_chaos_suite/3`
  - applies a suite-level timeout.
  - only true per-scenario deadline overruns are treated as timeout cutoffs.
  - scenarios that independently return `{:error, :timeout}` do not stop the suite.
- `assert_no_process_leaks/1`
  - tracks spawned/linked processes attributable to the operation.
  - catches delayed descendant leaks.
  - avoids flagging short-lived transient processes as leaks.

## Safety

- No unbounded dynamic atom creation is used for test IDs or isolation naming paths.
- ETS fallback injection (`ETSIsolation.inject_table/3-4`) uses existing atoms only and raises instead of creating dynamic atoms.

## Documentation

- [Documentation Index](guides/DOCS_INDEX.md)
- [Quick Start](guides/QUICK_START.md)
- [User Manual](guides/MANUAL.md)
- [API Guide](guides/API_GUIDE.md)
- [Changelog](CHANGELOG.md)

## Examples

- [Examples Index](examples/README.md)
- [EchoLab Example App](examples/echo_lab/README.md)

## License

MIT
