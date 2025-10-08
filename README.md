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

**Version 0.2.0** - Now with chaos engineering, performance testing, and supervision tree testing!

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

## Installation

Add `supertester` as a dependency in your `mix.exs` file. It's only needed for the `:test` environment.

```elixir
def deps do
  [
    {:supertester, "~> 0.2.0", only: :test}
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
  use ExUnit.Case, async: true # <-- Fully parallel!

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

## Core API Highlights

`Supertester` is organized into several modules, each targeting a specific area of OTP testing.

### `Supertester.OTPHelpers`
For setting up and managing isolated OTP processes.
- `setup_isolated_genserver/3`: Starts a `GenServer` with a unique name and automatic cleanup.
- `setup_isolated_supervisor/3`: Starts a `Supervisor` with a unique name and automatic cleanup.
- `wait_for_process_restart/3`: Blocks until a supervised process has been terminated and restarted.
- `wait_for_genserver_sync/2`: Ensures a `GenServer` is alive and responsive.

### `Supertester.GenServerHelpers`
For interacting with and testing `GenServer`s.
- `cast_and_sync/3`: Sends a `cast` and waits for a follow-up `call` to confirm it was processed.
- `get_server_state_safely/1`: Fetches `GenServer` state without crashing if the process is down.
- `test_server_crash_recovery/2`: Simulates a process crash and verifies its recovery by the supervisor.
- `concurrent_calls/3`: Stress-tests a `GenServer` with many concurrent requests.

### `Supertester.Assertions`
Custom, OTP-aware assertions for more meaningful tests.
- `assert_process_alive/1` & `assert_process_dead/1`
- `assert_genserver_state/2`: Asserts the `GenServer`'s internal state matches a value or passes a function check.
- `assert_child_count/2`: Asserts a supervisor has an exact number of active children.
- `assert_all_children_alive/1`: Checks that all children in a supervision tree are running.
- `assert_no_process_leaks/1`: Ensures an operation cleans up all the processes it spawns.

### `Supertester.UnifiedTestFoundation`
Provides advanced, case-level isolation for complex scenarios.

```elixir
defmodule MyApp.MyAdvancedTest do
  use ExUnit.Case
  # Choose an isolation level for the entire test module.
  # :full_isolation provides sandboxed processes and ETS tables.
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  test "this test runs in a complete sandbox", context do
    # `context.isolation_context` holds info about the sandbox.
    # All processes started via Supertester helpers are tracked and auto-cleaned.
    {:ok, server} = Supertester.OTPHelpers.setup_isolated_genserver(MyServer)
    # ... your isolated test logic ...
  end
end
```

### `Supertester.SupervisorHelpers`
Specialized testing for supervision trees and restart strategies.
- `test_restart_strategy/3`: Verify one_for_one, one_for_all, rest_for_one strategies
- `assert_supervision_tree_structure/2`: Validate supervision tree structure
- `trace_supervision_events/2`: Monitor supervisor events
- `wait_for_supervisor_stabilization/2`: Wait for all children to be ready

### `Supertester.ChaosHelpers`
Chaos engineering toolkit for resilience testing.
- `inject_crash/3`: Controlled crash injection (immediate, delayed, random)
- `chaos_kill_children/3`: Random child killing in supervision trees
- `simulate_resource_exhaustion/2`: Process/ETS/memory exhaustion simulation
- `assert_chaos_resilient/3`: Verify system recovery from chaos
- `run_chaos_suite/3`: Comprehensive chaos scenario testing

### `Supertester.PerformanceHelpers`
Performance testing and regression detection.
- `assert_performance/2`: Assert time/memory/reduction bounds
- `assert_no_memory_leak/2`: Detect memory leaks over iterations
- `measure_operation/1`: Measure time, memory, and CPU work
- `assert_mailbox_stable/2`: Ensure mailbox doesn't grow unbounded
- `compare_performance/2`: Compare multiple function performances

### `Supertester.TestableGenServer`
Automatic sync handler injection for GenServers.
- Automatically adds `__supertester_sync__` handler to any GenServer
- Enables deterministic testing without `Process.sleep/1`
- Works seamlessly with existing GenServer implementations

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
