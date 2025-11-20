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

**A battle-hardened OTP testing toolkit with chaos engineering, performance testing, and zero-sleep synchronization for building robust Elixir applications.**

**Version 0.3.1** - Now with concurrent harness, telemetry instrumentation, and chaos-aware mailbox tooling!

---

## The Problem: Flaky OTP Tests

Are you tired of...
- 😫 **Flaky tests** that fail randomly due to race conditions?
- 📛 **`GenServer` name clashes** when running tests with `async: true`?
- 🕰️ Littering your test suite with `Process.sleep/1` and hoping for the best?
- 🤷‍♂️ Struggling to test process crashes, restarts, and complex supervision trees?

Writing tests for concurrent systems is hard. Traditional testing methods often lead to fragile, non-deterministic, and slow test suites.

## The Solution: Supertester

`Supertester` provides a comprehensive suite of tools to write clean, deterministic, and reliable tests for your OTP applications. It replaces fragile timing hacks with robust synchronization patterns and provides powerful helpers for simulating and asserting complex OTP behaviors.

With `Supertester`, you can build a test suite that is **fast**, **parallel**, and **trustworthy**.

## Key Features

- ✅ **Rock-Solid Test Isolation**: Run all your tests with `async: true` without fear of process name collisions or state leakage.
- 🔄 **Zero Process.sleep**: Complete elimination of timing-based synchronization. Use proper OTP patterns for deterministic testing.
- 🤖 **Powerful OTP Assertions**: Go beyond `assert`. Use `assert_process_restarted/2`, `assert_genserver_state/2`, and `assert_all_children_alive/1` for more expressive tests.
- ✨ **Effortless Setup & Teardown**: Start isolated `GenServer`s and `Supervisor`s with a single line and trust `Supertester` to handle all the cleanup.
- 💥 **Chaos Engineering**: Test system resilience with controlled fault injection, random process crashes, and resource exhaustion.
- 🎯 **Supervision Tree Testing**: Verify restart strategies, trace supervision events, and validate tree structures.
- ⚡ **Performance Testing**: Assert performance SLAs, detect memory leaks, and prevent regressions with built-in benchmarking.
- 🔧 **TestableGenServer**: Automatic injection of sync handlers for deterministic async operation testing.
- 🧵 **Concurrent Harness**: Describe multi-threaded scenarios once and let Supertester orchestrate calls, casts, chaos hooks, performance checks, and mailbox monitoring without extra glue.
- 📊 **Telemetry Built-In**: Structured `:telemetry` events for scenario start/stop, mailbox sampling, chaos injections, and performance metrics so observability does not become an afterthought.

## Installation

Add `supertester` as a dependency in your `mix.exs` file. It's only needed for the `:test` environment.

```elixir
def deps do
  [
    {:supertester, "~> 0.3.1", only: :test}
  ]
end
```

Then, run `mix deps.get` to install.

## Quick Start: From Flaky to Robust

See how `Supertester` transforms a common, fragile test pattern into a robust, deterministic one.

#### Before: The Flaky Way

```elixir
# test/my_app/counter_test.exs
defmodule MyApp.CounterTest do
  use ExUnit.Case, async: false # <-- Forced to run sequentially

  test "incrementing the counter" do
    # Manual setup, prone to name conflicts
    {:ok, _pid} = start_supervised({Counter, name: Counter})

    GenServer.cast(Counter, :increment)
    Process.sleep(50) # <-- Fragile, timing-dependent guess

    state = GenServer.call(Counter, :state)
    assert state.count == 1
  end
end
```

#### After: The Supertester Way

```elixir
# test/my_app/counter_test.exs
defmodule MyApp.CounterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation # <-- Fully parallel!

  # Import the tools you need
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  test "incrementing the counter" do
    # Isolated setup with automatic cleanup, no name clashes
    {:ok, counter_pid} = setup_isolated_genserver(Counter)

    # Deterministic sync: ensures the cast is processed before continuing
    :ok = cast_and_sync(counter_pid, :increment)

    # Expressive, OTP-aware assertion for checking state
    assert_genserver_state(counter_pid, fn state -> state.count == 1 end)
  end
end
```

## Core Modules Overview

`Supertester` is organized into several powerful modules, each targeting a specific area of OTP testing.

- **`Supertester.ExUnitFoundation`**: Drop-in `ExUnit.Case` adapter that enables Supertester isolation with a single `use`, automatically configuring async support per isolation mode.

- **`Supertester.UnifiedTestFoundation`**: The isolation runtime powering Supertester. Call it directly from custom harnesses or advanced setups where you don’t want to use the ExUnit adapter.

- **`Supertester.TestableGenServer`**: A simple behavior to make your `GenServer`s more testable. It automatically injects handlers to allow deterministic synchronization in your tests, completely eliminating the need for `Process.sleep/1`.

- **`Supertester.OTPHelpers`**: Provides the essential tools for managing the lifecycle of isolated OTP processes. Functions like `setup_isolated_genserver/3` and `setup_isolated_supervisor/3` are your entry point for starting processes within the isolated test environment.

- **`Supertester.GenServerHelpers`**: Contains specialized functions for interacting with `GenServer`s. The star of this module is `cast_and_sync/2`, which provides a robust way to test asynchronous `cast` operations deterministically. It also includes helpers for stress-testing and crash recovery scenarios.

- **`Supertester.SupervisorHelpers`**: A dedicated toolkit for testing the backbone of OTP applications: supervisors. You can verify restart strategies, validate supervision tree structures, and trace supervision events to ensure your application is truly fault-tolerant.

- **`Supertester.ConcurrentHarness`**: Compose complex concurrent scenarios declaratively. Provide thread scripts, invariants, optional chaos hooks, performance expectations, and mailbox monitoring, then receive a structured report plus telemetry events for each run.

- **`Supertester.PropertyHelpers`**: Build `StreamData` generators that output ready-to-run concurrency scenarios. Feed them into `ConcurrentHarness` for property-based testing of GenServers and supervisors.

- **`Supertester.MessageHarness`**: Trace messages delivered to any process while executing a function. Perfect for debugging mailbox growth or validating ordering without invasive instrumentation.

- **`Supertester.Telemetry`**: Single entry point for emitting `:telemetry` events with the `[:supertester | ...]` prefix, covering scenario lifecycle, chaos hooks, mailbox samples, and performance measurements so you can plug into dashboards with minimal wiring.

- **`Supertester.ChaosHelpers`**: Unleash controlled chaos to test your system's resilience. This module allows you to inject faults, kill random processes, and simulate resource exhaustion to ensure your system can withstand turbulent conditions.

- **`Supertester.PerformanceHelpers`**: Integrate performance testing directly into your test suite. Assert that your code meets performance SLAs, detect memory leaks, and prevent performance regressions before they hit production.

- **`Supertester.Assertions`**: A rich set of custom assertions that understand OTP primitives. Go beyond simple equality checks with assertions like `assert_genserver_state/2`, `assert_all_children_alive/1`, and `assert_no_process_leaks/1` for more expressive and meaningful tests.

## Advanced Usage Examples

### Chaos Engineering

Test your system's resilience to failures:

```elixir
test "system survives random process crashes" do
  {:ok, supervisor} = setup_isolated_supervisor(MyApp.WorkerSupervisor)

  # Kill 50% of workers over 3 seconds
  report = chaos_kill_children(supervisor,
    kill_rate: 0.5,
    duration_ms: 3000,
    kill_interval_ms: 200
  )

  # Verify system recovered
  assert Process.alive?(supervisor)
  assert report.supervisor_crashed == false
  assert_all_children_alive(supervisor)
end

```

```elixir

# Mix chaos scenarios with concurrent harness runs
suite = [
  %{type: :kill_children, kill_rate: 0.3, duration_ms: 500},
  %{
    type: :concurrent,
    build: fn sup ->
      Supertester.ConcurrentHarness.simple_genserver_scenario(
        MyWorker,
        [{:cast, :do_work}, {:call, :get_state}],
        4,
        setup: fn -> {:ok, sup, %{}} end,
        cleanup: fn _, _ -> :ok end
      )
    end
  }
]

report = run_chaos_suite(supervisor, suite)
```

### Performance Testing

Ensure your code meets performance SLAs:

```elixir
test "API response time SLA" do
  {:ok, api_server} = setup_isolated_genserver(APIServer)

  assert_performance(
    fn -> APIServer.handle_request(api_server, :get_user) end,
    max_time_ms: 50,
    max_memory_bytes: 500_000,
    max_reductions: 100_000
  )
end

test "no memory leak in message processing" do
  {:ok, worker} = setup_isolated_genserver(MessageWorker)

  assert_no_memory_leak(10_000, fn ->
    MessageWorker.process(worker, generate_message())
  end)
end
```

### Supervision Tree Testing

Verify supervision strategies work correctly:

```elixir
test "one_for_one restarts only failed child" do
  {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

  result = test_restart_strategy(supervisor, :one_for_one,
    {:kill_child, :worker_1}
  )

  assert result.restarted == [:worker_1]
  assert :worker_2 in result.not_restarted
  assert :worker_3 in result.not_restarted
end

test "supervision tree structure" do
  {:ok, root} = setup_isolated_supervisor(RootSupervisor)

  assert_supervision_tree_structure(root, %{
    supervisor: RootSupervisor,
    strategy: :one_for_one,
    children: [
      {:cache, CacheServer},
      {:worker_pool, WorkerPoolSupervisor}
    ]
  })
end
```

## Documentation

For a comprehensive guide to all features, modules, and functions, please see the full **[User Manual](MANUAL.md)**.

The user manual includes:
- In-depth explanations of every module.
- Detailed function signatures, parameters, and return values.
- Practical code examples and recipes for common testing scenarios.
- Best practices for writing robust tests.

Additional documentation, including the technical design, can be found in the `docs/` directory.

## What's New in 0.2.0

- 🎉 **Zero Process.sleep**: Eliminated all timing-based synchronization
- 🎉 **ChaosHelpers**: Complete chaos engineering toolkit
- 🎉 **PerformanceHelpers**: Performance testing and regression detection
- 🎉 **SupervisorHelpers**: Comprehensive supervision tree testing
- 🎉 **TestableGenServer**: Automatic sync handler injection
- 🎉 **37 tests**: All passing with 100% async execution

See [CHANGELOG.md](CHANGELOG.md) for detailed changes.

## Contributing

Contributions are welcome! If you'd like to help improve `Supertester`, please feel free to:
1.  Fork the repository.
2.  Create a new feature branch.
3.  Add your feature or bug fix.
4.  Ensure all new code is covered by tests.
5.  Open a pull request.

## License

This project is licensed under the MIT License.
### Concurrency Harness + Chaos + Telemetry

```elixir
test "counter stays non-negative under chaos" do
  scenario =
    Supertester.ConcurrentHarness.simple_genserver_scenario(
      CounterServer,
      [{:cast, :increment}, {:cast, :decrement}],
      5,
      chaos: Supertester.ConcurrentHarness.chaos_kill_children(kill_rate: 0.2, duration_ms: 500),
      performance_expectations: [max_time_ms: 100],
      mailbox: [sampling_interval: 2],
      metadata: %{test: "counter chaos"}
    )

  assert {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
  assert report.metrics.total_operations == length(report.events)
  assert report.chaos
  assert report.performance.time_us
end
```

Attach to the telemetry events in your umbrella app:

```elixir
:telemetry.attach(
  "supertester",
  [:supertester, :concurrent, :scenario, :stop],
  fn _event, %{duration_ms: duration}, metadata, _ ->
    Logger.info("[supertester] scenario #{metadata.scenario_id} finished in #{duration}ms")
  end,
  nil
)
```
