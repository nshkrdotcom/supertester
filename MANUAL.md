# Supertester User Manual

**Version**: 0.2.0

Welcome to the comprehensive user manual for Supertester. This document provides a detailed overview of all modules and functions available in the Supertester toolkit.

## Table of Contents

1.  [Introduction](#introduction)
2.  [Core Concepts](#core-concepts)
    *   [Test Isolation](#test-isolation)
    *   [Zero `Process.sleep`](#zero-processsleep)
    *   [Automatic Cleanup](#automatic-cleanup)
    *   [Expressive Assertions](#expressive-assertions)
3.  [Installation](#installation)
4.  [Core Modules](#core-modules)
    *   [`Supertester`](#supertester)
    *   [`Supertester.ExUnitFoundation`](#supertesterexunitfoundation)
    *   [`Supertester.UnifiedTestFoundation`](#supertesterunifiedtestfoundation)
    *   [`Supertester.Env`](#supertesterenv)
    *   [`Supertester.TestableGenServer`](#supertestertestablegenserver)
5.  [OTP Testing Helpers](#otp-testing-helpers)
    *   [`Supertester.OTPHelpers`](#supertesterotphelpers)
    *   [`Supertester.GenServerHelpers`](#supertestergenserverhelpers)
    *   [`Supertester.SupervisorHelpers`](#supertestersupervisorhelpers)
6.  [Chaos Engineering](#chaos-engineering)
    *   [`Supertester.ChaosHelpers`](#supertesterchaoshelpers)
7.  [Performance Testing](#performance-testing)
    *   [`Supertester.PerformanceHelpers`](#supertesterperformancehelpers)
8.  [Concurrency Harness](#concurrency-harness)
    *   [`Supertester.ConcurrentHarness`](#supertesterconcurrentharness)
    *   [`Supertester.PropertyHelpers`](#supertesterpropertyhelpers)
    *   [`Supertester.MessageHarness`](#supertestermessageharness)
9.  [Telemetry & Diagnostics](#telemetry--diagnostics)
    *   [`Supertester.Telemetry`](#supertestertelemetry)
10. [Custom Assertions](#custom-assertions)
    *   [`Supertester.Assertions`](#supertesterassertions)
11. [Practical Examples & Recipes](#practical-examples--recipes)
    *   [Basic GenServer Test](#basic-genserver-test)
    *   [Supervisor Restart Strategy Test](#supervisor-restart-strategy-test)
    *   [Chaos Test for System Resilience](#chaos-test-for-system-resilience)
    *   [Performance SLA Test](#performance-sla-test)
    *   [Memory Leak Detection](#memory-leak-detection)
12. [Best Practices](#best-practices)
13. [Troubleshooting](#troubleshooting)

---

## Introduction

Supertester is a battle-hardened OTP testing toolkit designed to help you build robust and reliable Elixir applications. It provides a comprehensive suite of tools for testing concurrent systems, including features for chaos engineering, performance testing, and zero-sleep synchronization.

This manual will guide you through the features and best practices for using Supertester to its full potential.

## Core Concepts

### Test Isolation

Supertester provides robust test isolation, allowing you to run your tests concurrently (`async: true`) without worrying about process name collisions or state leakage. This is achieved through the `Supertester.UnifiedTestFoundation` runtime and its ExUnit adapter, `Supertester.ExUnitFoundation`, which create a sandboxed environment for each test.

### Zero `Process.sleep`

Timing-based synchronization (`Process.sleep/1`) is a common source of flaky tests. Supertester eliminates the need for this by providing deterministic synchronization patterns, such as `cast_and_sync/3`, which ensures that an asynchronous operation has completed before the test proceeds.

### Automatic Cleanup

All resources created using Supertester's helpers (e.g., `setup_isolated_genserver/3`) are automatically cleaned up at the end of each test. This prevents resource leaks and ensures that tests do not interfere with each other.

### Expressive Assertions

Supertester includes a rich set of OTP-aware assertions that make your tests more expressive and easier to read. For example, `assert_genserver_state/2` allows you to assert on the internal state of a GenServer without manually fetching it.

## Installation

To get started with Supertester, add it as a dependency in your `mix.exs` file. It's only required for the `:test` environment.

```elixir
def deps do
  [
    {:supertester, "~> 0.2.0", only: :test}
  ]
end
```

Then, run `mix deps.get` to install the dependency.

---

## Core Modules

### `Supertester`

The main module provides basic information about the library.

**`version()`**

Returns the current version of the Supertester library.

*   **Signature:** `@spec version() :: String.t()`
*   **Example:**
    ```elixir
    Supertester.version()
    #=> "0.2.0"
    ```

### `Supertester.ExUnitFoundation`

This module is the drop-in ExUnit adapter for Supertester isolation. Replace `use ExUnit.Case` with it to automatically configure the appropriate async setting and install the isolation `setup` callback.

**Usage:**

```elixir
defmodule MyApp.MyTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  test "an isolated test", context do
    # `context.isolation_context` contains isolation information.
    # All processes started with Supertester helpers are tracked and cleaned up.
  end
end
```

**Isolation Modes (`:isolation` option):**

*   `:basic`: Provides basic isolation with unique process naming (async-friendly).
*   `:registry`: Uses a dedicated registry for process isolation (async-friendly).
*   `:full_isolation`: Provides complete process and ETS table isolation. This is the recommended mode (async-friendly).
*   `:contamination_detection`: Detects if a test leaks processes or ETS tables (runs synchronously).

### `Supertester.UnifiedTestFoundation`

`Supertester.UnifiedTestFoundation` now focuses on the isolation runtime itself. Use it directly when integrating Supertester with a custom harness or non-ExUnit environment. The legacy `use Supertester.UnifiedTestFoundation` macro is still available but emits a compile-time warning—prefer `Supertester.ExUnitFoundation` for ExUnit integration.

**Manual usage example:**

```elixir
defmodule CustomHarnessTest do
  use ExUnit.Case, async: true

  setup context do
    Supertester.UnifiedTestFoundation.setup_isolation(:full_isolation, context)
  end

  test "custom integration", context do
    assert match?(%Supertester.IsolationContext{}, context.isolation_context)
  end
end
```

The value stored in `context.isolation_context` is a `%Supertester.IsolationContext{}` struct that captures the `test_id`, tracked processes, ETS tables, and contextual tags (module, test name, isolation mode, etc.), making it easy to log or inspect diagnostics.

### `Supertester.Env`

`Supertester.Env` abstracts how Supertester registers cleanup callbacks. By default it delegates to `ExUnit.Callbacks.on_exit/1`, but you can plug in a custom module (that implements the `Supertester.Env` behaviour) for other harnesses:

```elixir
defmodule MyHarness.Env do
  @behaviour Supertester.Env

  @impl true
  def on_exit(fun) do
    MyHarness.register_cleanup(fun)
  end
end

# config/test.exs
import Config
config :supertester, :env_module, MyHarness.Env
```

### `Supertester.TestableGenServer`

This behavior injects a `__supertester_sync__` handler into your GenServers, enabling deterministic testing of asynchronous operations without `Process.sleep/1`.

**Usage in your GenServer:**

```elixir
defmodule MyApp.MyServer do
  use GenServer
  use Supertester.TestableGenServer

  # Your GenServer implementation...
end
```

**Usage in your tests:**

```elixir
test "testing an async operation" do
  {:ok, server} = MyApp.MyServer.start_link()

  # Perform an async operation
  GenServer.cast(server, :some_async_work)

  # Wait for the operation to complete
  :ok = GenServer.call(server, :__supertester_sync__)

  # Now it's safe to assert the state
  assert_genserver_state(server, fn state -> state.work_done == true end)
end
```

The injected handler also supports returning the state directly:

```elixir
{:ok, state} = GenServer.call(server, {:__supertester_sync__, return_state: true})
```
---

## OTP Testing Helpers

### `Supertester.OTPHelpers`

This module contains core helpers for testing OTP-compliant processes.

**`setup_isolated_genserver(module, test_name \\ "", opts \\ [])`**

Starts an isolated `GenServer` with a unique name and automatic cleanup.

*   **Signature:** `@spec setup_isolated_genserver(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}`
*   **Parameters:**
    *   `module`: The `GenServer` module to start.
    *   `test_name` (optional): A name for the test context to ensure unique process naming.
    *   `opts` (optional): Options to pass to `GenServer.start_link/3`.
*   **Example:**
    ```elixir
    {:ok, server} = setup_isolated_genserver(MyServer, "my_test", [initial_state: %{}])
    ```

**`setup_isolated_supervisor(module, test_name \\ "", opts \\ [])`**

Starts an isolated `Supervisor` with a unique name and automatic cleanup.

*   **Signature:** `@spec setup_isolated_supervisor(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}`
*   **Example:**
    ```elixir
    {:ok, supervisor} = setup_isolated_supervisor(MySupervisor, "my_supervisor_test")
    ```

**`wait_for_genserver_sync(server, timeout \\ 1000)`**

Waits for a `GenServer` to be alive and responsive.

*   **Signature:** `@spec wait_for_genserver_sync(GenServer.server(), timeout()) :: :ok | {:error, term()}`
*   **Example:**
    ```elixir
    wait_for_genserver_sync(server_pid)
    ```

**`wait_for_process_restart(process_name, original_pid, timeout \\ 1000)`**

Waits for a supervised process to be terminated and restarted.

*   **Signature:** `@spec wait_for_process_restart(atom(), pid(), timeout()) :: {:ok, pid()} | {:error, term()}`
*   **Example:**
    ```elixir
    original_pid = GenServer.whereis(MyServer)
    GenServer.stop(MyServer)
    {:ok, new_pid} = wait_for_process_restart(MyServer, original_pid)
    ```

### `Supertester.GenServerHelpers`

This module provides helpers specifically for testing `GenServer`s.

**`get_server_state_safely(server)`**

Fetches the state of a `GenServer` without crashing if the process is down.

*   **Signature:** `@spec get_server_state_safely(GenServer.server()) :: {:ok, term()} | {:error, term()}`
*   **Example:**
    ```elixir
    {:ok, state} = get_server_state_safely(server_pid)
    ```

**`cast_and_sync(server, cast_message, sync_message \\ :__supertester_sync__, opts \\ [])`**

Sends a `cast` message and then waits for a follow-up `call` to confirm the cast was processed. This is the recommended way to test async operations.

*   **Signature:** `@spec cast_and_sync(GenServer.server(), term(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}`
*   **Options:** `:strict?` (default `false`) raises when the target server doesn't implement the sync handler; `:timeout` to customize the sync call timeout.
*   **Example:**
    ```elixir
    :ok = cast_and_sync(counter_pid, :increment)
    assert_genserver_state(counter_pid, fn state -> state.count == 1 end)

    # Enforce the presence of the sync handler
    assert_raise ArgumentError do
      cast_and_sync(counter_pid, :increment, :__supertester_sync__, strict?: true)
    end
    ```

**`test_server_crash_recovery(server, crash_reason)`**

Simulates a process crash and verifies its recovery by its supervisor.

*   **Signature:** `@spec test_server_crash_recovery(GenServer.server(), term()) :: {:ok, map()} | {:error, term()}`
*   **Example:**
    ```elixir
    {:ok, info} = test_server_crash_recovery(server_pid, :test_crash)
    assert info.recovered == true
    ```

**`concurrent_calls(server, calls, count \\ 10, opts \\ [])`**

Stress-tests a `GenServer` with many concurrent requests.

*   **Signature:** `@spec concurrent_calls(GenServer.server(), [term()], pos_integer(), keyword()) :: {:ok, [map()]}` (`opts[:timeout]` controls the per-call timeout)
*   **Example:**
    ```elixir
    calls = [:get_counter, {:increment, 1}]
    {:ok, results} = concurrent_calls(server_pid, calls, 20, timeout: 50)

    Enum.each(results, fn %{call: call, successes: successes, errors: errors} ->
      IO.inspect({call, length(successes), length(errors)})
    end)
    ```

### `Supertester.SupervisorHelpers`

This module provides helpers for testing supervision trees and restart strategies.

**`test_restart_strategy(supervisor, strategy, scenario)`**

Tests a supervisor's restart strategy (`:one_for_one`, `:one_for_all`, etc.) with a given failure scenario.

*   **Signature:** `@spec test_restart_strategy(Supervisor.supervisor(), atom(), restart_scenario()) :: test_result()`
*   **Example:**
    ```elixir
    result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})
    assert result.restarted == [:worker_1]
    assert :worker_2 in result.not_restarted
    ```

**`assert_supervision_tree_structure(supervisor, expected)`**

Validates the structure of a supervision tree.

*   **Signature:** `@spec assert_supervision_tree_structure(Supervisor.supervisor(), tree_structure()) :: :ok`
*   **Example:**
    ```elixir
    assert_supervision_tree_structure(root_supervisor, %{
      supervisor: RootSupervisor,
      strategy: :one_for_one,
      children: [
        {:cache, CacheServer},
        {:worker_pool, WorkerPoolSupervisor}
      ]
    })
    ```

**`trace_supervision_events(supervisor, opts \\ [])`**

Monitors and returns all supervision events (e.g., child started, terminated, restarted) that occur during a test.

*   **Signature:** `@spec trace_supervision_events(Supervisor.supervisor(), keyword()) :: {:ok, (-> [supervision_event()])}`
*   **Example:**
    ```elixir
    {:ok, stop_trace} = trace_supervision_events(supervisor)
    # ... cause a failure ...
    events = stop_trace.()
    assert Enum.any?(events, &match?({:child_restarted, _, _, _}, &1))
    ```

**`wait_for_supervisor_stabilization(supervisor, timeout \\ 5000)`**

Waits for a supervisor to have all its children running and stable, which is useful after inducing failures.

*   **Signature:** `@spec wait_for_supervisor_stabilization(Supervisor.supervisor(), timeout()) :: :ok | {:error, :timeout}`
*   **Example:**
    ```elixir
    # ... cause chaos ...
    :ok = wait_for_supervisor_stabilization(supervisor)
    assert_all_children_alive(supervisor)
    ```

---

## Chaos Engineering

### `Supertester.ChaosHelpers`

This module provides a toolkit for chaos engineering to test the resilience of your system.

**`inject_crash(target, crash_spec, opts \\ [])`**

Injects a controlled crash into a process.

*   **Signature:** `@spec inject_crash(pid(), crash_spec(), keyword()) :: :ok`
*   **Crash Specifications:**
    *   `:immediate`: Crashes the process immediately.
    *   `{:after_ms, duration}`: Crashes after a delay.
    *   `{:random, probability}`: Crashes with a given probability (0.0 to 1.0).
*   **Example:**
    ```elixir
    inject_crash(worker_pid, :immediate)
    inject_crash(worker_pid, {:random, 0.5}) # 50% chance of crash
    ```

**`chaos_kill_children(supervisor, opts \\ [])`**

Randomly kills children in a supervision tree to test restart strategies and system resilience.

*   **Signature:** `@spec chaos_kill_children(Supervisor.supervisor(), keyword()) :: chaos_report()`
*   **Options:** `:kill_rate`, `:duration_ms`, `:kill_interval_ms`
*   **Example:**
    ```elixir
    report = chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 3000)
    assert report.supervisor_crashed == false
    ```

**`simulate_resource_exhaustion(resource, opts \\ [])`**

Simulates resource exhaustion scenarios, such as process or ETS table limits.

*   **Signature:** `@spec simulate_resource_exhaustion(atom(), keyword()) :: {:ok, cleanup_fn :: (-> :ok)} | {:error, term()}`
*   **Resources:** `:process_limit`, `:ets_tables`, `:memory`
*   **Example:**
    ```elixir
    {:ok, cleanup} = simulate_resource_exhaustion(:process_limit, spawn_count: 1000)
    # ... perform tests under pressure ...
    cleanup.()
    ```

**`assert_chaos_resilient(system, chaos_fn, recovery_fn, opts \\ [])`**

Asserts that a system recovers from a chaos scenario within a given timeout.

*   **Signature:** `@spec assert_chaos_resilient(pid(), (-> any()), (-> boolean()), keyword()) :: :ok`
*   **Example:**
    ```elixir
    assert_chaos_resilient(supervisor,
      fn -> chaos_kill_children(supervisor, kill_rate: 0.5) end,
      fn -> all_workers_are_healthy?(supervisor) end,
      timeout: 10_000
    )
    ```

**`run_chaos_suite(target, scenarios, opts \\ [])`**

Executes a list of chaos scenarios—now including full `Supertester.ConcurrentHarness` scenarios—
against the same target process or supervisor so you can orchestrate concurrent workloads while
injecting faults.

*   **Signature:** `@spec run_chaos_suite(pid(), [map()], keyword()) :: chaos_suite_report()`
*   **Concurrent Scenarios:** Provide `%{type: :concurrent, build: fn target -> scenario end}` or
    `%{type: :concurrent, scenario: <ConcurrentHarness scenario>}` entries to reuse the harness with
    shared telemetry/reporting.
*   **Example:**
    ```elixir
    scenarios = [
      %{type: :kill_children, kill_rate: 0.4, duration_ms: 500},
      %{
        type: :concurrent,
        build: fn supervisor ->
          Supertester.ConcurrentHarness.simple_genserver_scenario(
            MyWorker,
            [{:cast, :do_work}, {:call, :get_state}],
            3,
            setup: fn -> {:ok, supervisor, %{}} end,
            cleanup: fn _, _ -> :ok end
          )
        end
      }
    ]

    report = run_chaos_suite(supervisor, scenarios, timeout: 10_000)
    assert report.failed == 0
    ```

---

## Performance Testing

### `Supertester.PerformanceHelpers`

This module provides tools for performance testing and regression detection.

**`assert_performance(operation, expectations)`**

Asserts that an operation meets specific performance bounds.

*   **Signature:** `@spec assert_performance((-> any()), keyword()) :: :ok`
*   **Expectations:** `:max_time_ms`, `:max_memory_bytes`, `:max_reductions`
*   **Example:**
    ```elixir
    assert_performance(
      fn -> APIServer.get_user(1) end,
      max_time_ms: 50,
      max_memory_bytes: 500_000
    )
    ```

**`assert_no_memory_leak(iterations, operation, opts \\ [])`**

Detects memory leaks by running an operation many times and checking for memory growth.

*   **Signature:** `@spec assert_no_memory_leak(pos_integer(), (-> any()), keyword()) :: :ok`
*   **Example:**
    ```elixir
    assert_no_memory_leak(10_000, fn ->
      MessageWorker.process(worker, generate_message())
    end)
    ```

**`measure_operation(operation)`**

Measures the performance metrics of an operation.

*   **Signature:** `@spec measure_operation((-> any())) :: map()`
*   **Returns:** A map with `:time_us`, `:memory_bytes`, `:reductions`, and `:result`.
*   **Example:**
    ```elixir
    metrics = measure_operation(fn -> complex_calculation() end)
    IO.inspect(metrics)
    ```

**`assert_mailbox_stable(server, opts)`**

Asserts that a GenServer's mailbox does not grow uncontrollably during an operation.

*   **Signature:** `@spec assert_mailbox_stable(pid(), keyword()) :: :ok`
*   **Options:** `:during` (the function to execute), `:max_size` (max allowed mailbox size).
*   **Example:**
    ```elixir
    assert_mailbox_stable(server,
      during: fn -> send_many_messages(server, 1000) end,
      max_size: 50
    )
    ```

---

## Concurrency Harness

### `Supertester.ConcurrentHarness`

The concurrency harness lets you describe complex multi-threaded scenarios declaratively.
Provide a `setup` function, thread scripts (lists of operations), optional mailbox monitoring,
chaos hooks, performance expectations, and an invariant function. `run/1` coordinates each thread,
synchronizes casts with `Supertester.TestableGenServer`, records every event, emits telemetry, and
returns a diagnostic report:

```elixir
scenario =
  Supertester.ConcurrentHarness.simple_genserver_scenario(
    CounterServer,
    [{:cast, :increment}, {:call, :value}],
    4,
    mailbox: [sampling_interval: 1],
    chaos: Supertester.ConcurrentHarness.chaos_inject_crash(),
    performance_expectations: [max_time_ms: 100],
    invariant: fn server, ctx ->
      {:ok, state} = Supertester.GenServerHelpers.get_server_state_safely(server)
      assert state.count >= 0
      assert ctx.metrics.total_operations > 0
    end
  )

assert {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
```

Use `from_property_config/3` to convert property-test generators straight into runnable scenarios.
Scenario metadata automatically includes a `:scenario_id`, and every run emits
`[:supertester, :concurrent, :scenario, :start|:stop]` telemetry events for observability.

Additional helpers:

* `chaos_kill_children/1` / `chaos_inject_crash/2` – build ready-made chaos hooks.
* `run_with_performance/2` – wrap an ad-hoc scenario with performance bounds outside of the struct.

### `Supertester.PropertyHelpers`

`PropertyHelpers` builds on `StreamData` to emit normalized operations and scenario configs that the
concurrent harness understands. `genserver_operation_sequence/2` normalizes operations into tagged
`{:call, term}` / `{:cast, term}` tuples, while `concurrent_scenario/1` generates complete configs:

```elixir
use ExUnitProperties

property "counter invariants hold" do
  generator =
    Supertester.PropertyHelpers.concurrent_scenario(
      operations: [{:cast, :increment}, {:cast, :decrement}, {:call, :value}],
      min_threads: 1,
      max_threads: 3
    )

  check all cfg <- generator do
    scenario = Supertester.ConcurrentHarness.from_property_config(CounterServer, cfg)
    assert {:ok, _report} = Supertester.ConcurrentHarness.run(scenario)
  end
end
```

If `:stream_data` is not present in your project, these helpers raise a clear error suggesting the
dependency addition.

### `Supertester.MessageHarness`

`MessageHarness.trace_messages/3` snapshots a process mailbox, enables `:erlang.trace` for
`:receive` events, runs your function, then returns the captured messages and result. It is
ideal for debugging concurrency issues without changing application code.

```elixir
report =
  Supertester.MessageHarness.trace_messages(server, fn ->
    send(server, {:direct, :hello})
  end)

assert {:direct, :hello} in report.messages
```

---

## Telemetry & Diagnostics

### `Supertester.Telemetry`

Supertester emits `:telemetry` events under the `[:supertester | ...]` namespace. The helper
module centralizes emission so you can subscribe once and observe:

* `[:supertester, :concurrent, :scenario, :start|:stop]` – scenario lifecycle with duration/status.
* `[:supertester, :concurrent, :mailbox, :sample]` – mailbox measurements collected during runs.
* `[:supertester, :chaos, :start|:stop]` – chaos hooks firing, including duration and failures.
* `[:supertester, :performance, :scenario, :measured]` – performance metrics captured for scenarios.

Attach handlers with `:telemetry.attach/4` or `attach_many/4`:

```elixir
:telemetry.attach(
  "supertester-console",
  [:supertester, :concurrent, :scenario, :stop],
  fn _event, %{duration_ms: duration}, metadata, _ ->
    Logger.info("Scenario #{metadata.scenario_id} took #{duration}ms (#{metadata[:status] || :ok})")
  end,
  nil
)
```

---

## Custom Assertions

### `Supertester.Assertions`

This module provides a set of custom, OTP-aware assertions.

*   `assert_process_alive(pid)` / `assert_process_dead(pid)`
*   `assert_process_restarted(process_name, original_pid)`
*   `assert_genserver_state(server, expected_state_or_fun)`
*   `assert_genserver_responsive(server)`
*   `assert_child_count(supervisor, expected_count)`
*   `assert_all_children_alive(supervisor)`
*   `assert_no_process_leaks(operation_fun)`
*   `assert_memory_usage_stable(operation_fun, tolerance)`

**Example: `assert_genserver_state/2`**

This assertion can take an exact state or a function to validate the state.

```elixir
# Exact match
assert_genserver_state(server, %{count: 5})

# Function validation
assert_genserver_state(server, fn state ->
  state.count > 0 and state.status == :active
end)
```

---

## Practical Examples & Recipes

### Basic GenServer Test

```elixir
defmodule MyApp.CounterTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  test "counter increments correctly" do
    {:ok, counter} = setup_isolated_genserver(Counter)
    :ok = cast_and_sync(counter, :increment)
    assert_genserver_state(counter, fn s -> s.count == 1 end)
  end
end
```

### Supervisor Restart Strategy Test

```elixir
defmodule MyApp.MySupervisorTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, SupervisorHelpers, Assertions}

  test "one_for_one strategy restarts only the failed child" do
    {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)
    result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})
    assert result.restarted == [:worker_1]
    wait_for_supervisor_stabilization(supervisor)
    assert_all_children_alive(supervisor)
  end
end
```

### Chaos Test for System Resilience

```elixir
defmodule MyApp.ResilienceTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, ChaosHelpers, Assertions}

  test "system survives random worker crashes" do
    {:ok, supervisor} = setup_isolated_supervisor(WorkerSupervisor)
    report = chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 2000)
    assert Process.alive?(supervisor)
    assert_all_children_alive(supervisor)
  end
end
```

### Performance SLA Test

```elixir
defmodule MyApp.PerformanceTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, PerformanceHelpers}

  test "API endpoint meets performance SLA" do
    {:ok, api_server} = setup_isolated_genserver(APIServer)
    assert_performance(
      fn -> APIServer.get_user(api_server, 123) end,
      max_time_ms: 100,
      max_memory_bytes: 1_000_000
    )
  end
end
```

### Memory Leak Detection

```elixir
defmodule MyApp.MemoryTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, PerformanceHelpers}

  test "worker does not leak memory" do
    {:ok, worker} = setup_isolated_genserver(Worker)
    assert_no_memory_leak(10_000, fn ->
      Worker.process(worker, generate_message())
    end)
  end
end
```

---

## Best Practices

1.  **Always Use Isolation:** Start your test modules with `use Supertester.ExUnitFoundation, isolation: :full_isolation`.
2.  **Prefer `setup_isolated_*`:** Use `setup_isolated_genserver` and `setup_isolated_supervisor` to ensure automatic cleanup and unique naming.
3.  **Avoid `Process.sleep`:** Use `cast_and_sync` for asynchronous operations and `wait_for_*` helpers for other synchronization needs.
4.  **Use Expressive Assertions:** Leverage the custom assertions in `Supertester.Assertions` to make your tests clearer and more concise.
5.  **Test for Resilience:** Use the `ChaosHelpers` to inject faults and ensure your system can handle them gracefully.
6.  **Assert Performance:** Use `PerformanceHelpers` to set performance SLAs and prevent regressions.

## Troubleshooting

*   **Flaky Tests:** If your tests are still flaky, ensure every asynchronous operation is followed by a synchronization helper like `cast_and_sync`.
*   **Name Conflicts:** If you encounter name clashes, make sure you are using `setup_isolated_genserver` for all your processes.
*   **Supervisor Tests Failing:** After inducing failures in a supervisor test, always use `wait_for_supervisor_stabilization` before making assertions about its children.
*   **Inconsistent Performance Tests:** Run `:erlang.garbage_collect()` before measuring performance and use a sufficient number of iterations to get stable results.
