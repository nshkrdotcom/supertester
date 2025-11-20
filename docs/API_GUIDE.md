# Supertester API Guide
**Version**: 0.2.0
**Last Updated**: October 7, 2025

Complete reference guide for all Supertester modules and functions.

---

## Table of Contents

1. [Core Modules](#core-modules)
2. [OTP Testing](#otp-testing)
3. [Chaos Engineering](#chaos-engineering)
4. [Performance Testing](#performance-testing)
5. [Assertions](#assertions)
6. [Quick Reference](#quick-reference)

---

## Core Modules

### Supertester

Main module providing version information.

```elixir
Supertester.version()
# => "0.2.0"
```

### Supertester.ExUnitFoundation

Drop-in ExUnit adapter that configures isolation automatically.

#### Isolation Modes (`:isolation` option)

- **`:basic`** – Basic isolation with unique naming (async-friendly)
- **`:registry`** – Registry-based process isolation (async-friendly)
- **`:full_isolation`** – Complete process and ETS isolation (recommended, async-friendly)
- **`:contamination_detection`** – Isolation with leak detection (runs synchronously)

#### Usage

```elixir
defmodule MyApp.MyTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  test "isolated test", context do
    # context.isolation_context contains isolation info
    {:ok, server} = setup_isolated_genserver(MyServer)
    # Test runs in complete isolation
  end
end
```

### Supertester.UnifiedTestFoundation

Isolation runtime powering Supertester. Use it directly for custom harnesses or non-ExUnit integrations. The legacy `use Supertester.UnifiedTestFoundation` macro delegates to `Supertester.ExUnitFoundation` and emits a warning.

```elixir
defmodule CustomHarnessTest do
  use ExUnit.Case, async: true

  setup context do
    Supertester.UnifiedTestFoundation.setup_isolation(:full_isolation, context)
  end
end
```

### Supertester.Env

Environment abstraction used to register cleanup callbacks. The default implementation uses `ExUnit.Callbacks.on_exit/1`, but you can configure a custom module that implements the `Supertester.Env` behaviour:

```elixir
defmodule MyHarness.Env do
  @behaviour Supertester.Env

  @impl true
  def on_exit(fun), do: MyHarness.register_cleanup(fun)
end

# config/test.exs
import Config
config :supertester, :env_module, MyHarness.Env
```

### Supertester.TestableGenServer

Automatically injects sync handlers into GenServers for deterministic testing.

#### Usage in GenServer

```elixir
defmodule MyServer do
  use GenServer
  use Supertester.TestableGenServer  # Adds __supertester_sync__ handler

  # Your GenServer implementation
end
```

#### Usage in Tests

```elixir
test "async operations" do
  {:ok, server} = MyServer.start_link()

  # Send async cast
  GenServer.cast(server, :some_operation)

  # Synchronize - ensures cast is processed
  GenServer.call(server, :__supertester_sync__)

  # Now safe to verify
  assert :sys.get_state(server).operation_complete == true
end
```

#### With State Return

```elixir
# Get state without :sys.get_state
{:ok, state} = GenServer.call(server, {:__supertester_sync__, return_state: true})
```

---

## OTP Testing

### Supertester.OTPHelpers

Core OTP testing utilities.

#### setup_isolated_genserver/3

Sets up an isolated GenServer with automatic cleanup.

```elixir
@spec setup_isolated_genserver(module(), String.t(), keyword()) ::
        {:ok, pid()} | {:error, term()}
```

**Parameters**:
- `module` - The GenServer module
- `test_name` - Test context for unique naming (optional, default: "")
- `opts` - Options passed to `GenServer.start_link` (optional, default: [])

**Example**:
```elixir
{:ok, server} = setup_isolated_genserver(MyServer, "test_1")
{:ok, server} = setup_isolated_genserver(MyServer, "test_2", init_args: [config: :test])
```

#### setup_isolated_supervisor/3

Sets up an isolated Supervisor with automatic cleanup.

```elixir
@spec setup_isolated_supervisor(module(), String.t(), keyword()) ::
        {:ok, pid()} | {:error, term()}
```

**Example**:
```elixir
{:ok, supervisor} = setup_isolated_supervisor(MySupervisor)
```

#### wait_for_genserver_sync/2

Waits for GenServer to be responsive.

```elixir
@spec wait_for_genserver_sync(GenServer.server(), timeout()) ::
        :ok | {:error, term()}
```

**Example**:
```elixir
{:ok, server} = MyServer.start_link()
:ok = wait_for_genserver_sync(server, 5000)
```

#### wait_for_process_restart/3

Waits for a process to restart after termination.

```elixir
@spec wait_for_process_restart(atom(), pid(), timeout()) ::
        {:ok, pid()} | {:error, term()}
```

**Example**:
```elixir
original_pid = Process.whereis(MyServer)
GenServer.stop(MyServer)
{:ok, new_pid} = wait_for_process_restart(MyServer, original_pid, 1000)
assert new_pid != original_pid
```

### Supertester.GenServerHelpers

GenServer-specific testing patterns.

#### get_server_state_safely/1

Safely retrieves GenServer state without crashing.

```elixir
@spec get_server_state_safely(GenServer.server()) ::
        {:ok, term()} | {:error, term()}
```

**Example**:
```elixir
{:ok, state} = get_server_state_safely(server)
assert state.counter == 5
```

#### cast_and_sync/4

Sends a cast and synchronizes to ensure processing.

```elixir
@spec cast_and_sync(GenServer.server(), term(), term(), keyword()) ::
        :ok | {:ok, term()} | {:error, term()}
```

**Example**:
```elixir
# No more Process.sleep!
:ok = cast_and_sync(server, {:increment, 5})
{:ok, state} = get_server_state_safely(server)
assert state.counter == 5
```

#### concurrent_calls/3

Stress-tests GenServer with concurrent calls.

```elixir
@spec concurrent_calls(GenServer.server(), [term()], pos_integer(), keyword()) ::
        {:ok, [map()]}
```

**Example**:
```elixir
{:ok, results} = concurrent_calls(server, [:increment, :decrement], 10, timeout: 20)

for %{call: call, successes: successes, errors: errors} <- results do
  IO.inspect({call, successes, errors})
end
```

#### stress_test_server/4

Runs a short stress scenario with mixed calls and casts.

```elixir
@spec stress_test_server(GenServer.server(), [term()], pos_integer(), keyword()) ::
        {:ok, %{calls: non_neg_integer, casts: non_neg_integer, errors: non_neg_integer, duration_ms: non_neg_integer}}
```

**Example**:
```elixir
operations = [
  {:call, :get_state},
  {:cast, {:queue_job, payload()}}
]

{:ok, report} = stress_test_server(server, operations, 1_000, workers: 4)
assert report.errors == 0
```

#### test_server_crash_recovery/2

Tests GenServer crash and recovery behavior.

```elixir
@spec test_server_crash_recovery(GenServer.server(), term()) ::
        {:ok, map()} | {:error, term()}
```

**Example**:
```elixir
{:ok, info} = test_server_crash_recovery(server, :test_crash)
assert info.recovered == true
assert info.new_pid != info.original_pid
```

### Supertester.SupervisorHelpers

Supervision tree testing utilities.

#### test_restart_strategy/3

Tests supervisor restart strategies.

```elixir
@spec test_restart_strategy(Supervisor.supervisor(), atom(), restart_scenario()) ::
        test_result()
```

**Strategies**: `:one_for_one`, `:one_for_all`, `:rest_for_one`

**Scenarios**:
- `{:kill_child, child_id}`
- `{:kill_children, [child_id]}`

**Example**:
```elixir
result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})

assert result.restarted == [:worker_1]
assert result.not_restarted == [:worker_2, :worker_3]
assert result.supervisor_alive == true
```

#### assert_supervision_tree_structure/2

Verifies supervision tree matches expected structure.

```elixir
@spec assert_supervision_tree_structure(Supervisor.supervisor(), tree_structure()) :: :ok
```

**Example**:
```elixir
assert_supervision_tree_structure(root_supervisor, %{
  supervisor: RootSupervisor,
  strategy: :one_for_one,
  children: [
    {:cache, CacheServer},
    {:worker_pool, %{
      supervisor: WorkerPoolSupervisor,
      strategy: :one_for_all,
      children: [
        {:worker_1, Worker},
        {:worker_2, Worker}
      ]
    }}
  ]
})
```

#### trace_supervision_events/2

Monitors supervisor for restart events.

```elixir
@spec trace_supervision_events(Supervisor.supervisor(), keyword()) ::
        {:ok, (() -> [supervision_event()])}
```

**Events**:
- `{:child_started, child_id, pid}`
- `{:child_terminated, child_id, pid, reason}`
- `{:child_restarted, child_id, old_pid, new_pid}`

**Example**:
```elixir
{:ok, stop_trace} = trace_supervision_events(supervisor)

# Cause failures
Process.exit(child_pid, :kill)

events = stop_trace.()
assert Enum.any?(events, &match?({:child_restarted, _, _, _}, &1))
```

#### wait_for_supervisor_stabilization/2

Waits until all children are running.

```elixir
@spec wait_for_supervisor_stabilization(Supervisor.supervisor(), timeout()) ::
        :ok | {:error, :timeout}
```

**Example**:
```elixir
# Cause chaos
Enum.each(children, fn {_id, pid, _type, _mods} ->
  Process.exit(pid, :kill)
end)

# Wait for recovery
:ok = wait_for_supervisor_stabilization(supervisor)
assert_all_children_alive(supervisor)
```

---

## Chaos Engineering

### Supertester.ChaosHelpers

Chaos engineering toolkit for resilience testing.

#### inject_crash/3

Injects controlled crashes into processes.

```elixir
@spec inject_crash(pid(), crash_spec(), keyword()) :: :ok
```

**Crash Specifications**:
- `:immediate` - Crash immediately
- `{:after_ms, duration}` - Crash after delay
- `{:random, probability}` - Crash with probability (0.0 to 1.0)

**Example**:
```elixir
# Immediate crash
inject_crash(worker_pid, :immediate)

# Delayed crash (100ms)
inject_crash(worker_pid, {:after_ms, 100})

# Random crash (30% probability)
inject_crash(worker_pid, {:random, 0.3}, reason: :chaos_test)
```

#### chaos_kill_children/3

Randomly kills children in supervision tree.

```elixir
@spec chaos_kill_children(Supervisor.supervisor(), keyword()) :: chaos_report()
```

**Options**:
- `:kill_rate` - Percentage of children to kill (default: 0.3)
- `:duration_ms` - How long to run chaos (default: 5000)
- `:kill_interval_ms` - Time between kills (default: 100)
- `:kill_reason` - Reason for kills (default: :kill)

**Example**:
```elixir
report = chaos_kill_children(supervisor,
  kill_rate: 0.5,  # Kill 50% of children
  duration_ms: 3000,
  kill_interval_ms: 200
)

assert report.killed > 0
assert report.supervisor_crashed == false
```

#### simulate_resource_exhaustion/2

Simulates resource limit scenarios.

```elixir
@spec simulate_resource_exhaustion(atom(), keyword()) ::
        {:ok, cleanup_fn()} | {:error, term()}
```

**Resources**:
- `:process_limit` - Spawn many processes
- `:ets_tables` - Create many ETS tables
- `:memory` - Allocate memory

**Example**:
```elixir
test "system handles process pressure" do
  {:ok, cleanup} = simulate_resource_exhaustion(:process_limit,
    spawn_count: 1000
  )

  # Test under pressure
  result = perform_operation()

  # Cleanup
  cleanup.()

  # Verify graceful degradation
  assert match?({:ok, _} | {:error, :resource_limit}, result)
end
```

#### assert_chaos_resilient/3

Asserts system recovers from chaos.

```elixir
@spec assert_chaos_resilient(pid(), (() -> any()), (() -> boolean()), keyword()) :: :ok
```

**Example**:
```elixir
assert_chaos_resilient(supervisor,
  fn -> chaos_kill_children(supervisor, kill_rate: 0.5) end,
  fn -> all_workers_alive?(supervisor) end,
  timeout: 10_000
)
```

#### run_chaos_suite/3

Runs comprehensive chaos scenario testing.

```elixir
@spec run_chaos_suite(pid(), [map()], keyword()) :: chaos_suite_report()
```

**Example**:
```elixir
scenarios = [
  %{type: :kill_children, kill_rate: 0.3, duration_ms: 1000},
  %{type: :kill_children, kill_rate: 0.5, duration_ms: 2000},
]

report = run_chaos_suite(supervisor, scenarios, timeout: 30_000)

assert report.passed == 2
assert report.failed == 0
```

---

## Performance Testing

### Supertester.PerformanceHelpers

Performance testing and regression detection.

#### assert_performance/2

Asserts operation meets performance bounds.

```elixir
@spec assert_performance((() -> any()), keyword()) :: :ok
```

**Expectations**:
- `:max_time_ms` - Maximum execution time
- `:max_memory_bytes` - Maximum memory consumption
- `:max_reductions` - Maximum CPU work

**Example**:
```elixir
test "API meets performance SLA" do
  assert_performance(
    fn -> API.get_user(1) end,
    max_time_ms: 50,
    max_memory_bytes: 1_000_000,
    max_reductions: 100_000
  )
end
```

#### assert_no_memory_leak/2

Detects memory leaks over many iterations.

```elixir
@spec assert_no_memory_leak(pos_integer(), (() -> any()), keyword()) :: :ok
```

**Options**:
- `:threshold` - Acceptable growth rate (default: 0.1 = 10%)

**Example**:
```elixir
test "no memory leak in message handling" do
  {:ok, worker} = setup_isolated_genserver(Worker)

  assert_no_memory_leak(10_000, fn ->
    Worker.handle_message(worker, random_message())
  end, threshold: 0.05)
end
```

#### measure_operation/1

Measures operation performance metrics.

```elixir
@spec measure_operation((() -> any())) :: map()
```

**Returns**:
- `:time_us` - Execution time in microseconds
- `:memory_bytes` - Memory used
- `:reductions` - CPU work
- `:result` - Operation result

**Example**:
```elixir
metrics = measure_operation(fn ->
  expensive_calculation()
end)

IO.puts "Time: #{metrics.time_us}μs"
IO.puts "Memory: #{metrics.memory_bytes} bytes"
IO.puts "Reductions: #{metrics.reductions}"
```

#### measure_mailbox_growth/2

Monitors mailbox size during operation.

```elixir
@spec measure_mailbox_growth(pid(), (() -> any())) :: map()
```

**Returns**:
- `:initial_size` - Mailbox size before
- `:final_size` - Mailbox size after
- `:max_size` - Maximum observed
- `:avg_size` - Average size

**Example**:
```elixir
report = measure_mailbox_growth(server, fn ->
  send_many_messages(server, 1000)
end)

assert report.max_size < 100
```

#### assert_mailbox_stable/2

Asserts mailbox doesn't grow unbounded.

```elixir
@spec assert_mailbox_stable(pid(), keyword()) :: :ok
```

**Options**:
- `:during` - Function to execute (required)
- `:max_size` - Maximum mailbox size (default: 100)

**Example**:
```elixir
assert_mailbox_stable(server,
  during: fn ->
    for _ <- 1..1000 do
      GenServer.cast(server, :work)
    end
  end,
  max_size: 50
)
```

#### compare_performance/2

Compares performance of multiple functions.

```elixir
@spec compare_performance(map()) :: map()
```

**Example**:
```elixir
results = compare_performance(%{
  "approach_a" => fn -> approach_a() end,
  "approach_b" => fn -> approach_b() end,
  "approach_c" => fn -> approach_c() end
})

# Find fastest
fastest = Enum.min_by(results, fn {_name, m} -> m.time_us end)
{name, metrics} = fastest
IO.puts "Fastest: #{name} at #{metrics.time_us}μs"
```

---

## Assertions

### Supertester.Assertions

Custom OTP-aware assertions.

#### assert_process_alive/1

```elixir
@spec assert_process_alive(pid()) :: :ok
```

**Example**:
```elixir
assert_process_alive(server_pid)
```

#### assert_process_dead/1

```elixir
@spec assert_process_dead(pid()) :: :ok
```

#### assert_process_restarted/2

```elixir
@spec assert_process_restarted(atom(), pid()) :: :ok
```

**Example**:
```elixir
original = Process.whereis(MyServer)
GenServer.stop(MyServer)
assert_process_restarted(MyServer, original)
```

#### assert_genserver_state/2

Asserts GenServer has expected state.

```elixir
@spec assert_genserver_state(GenServer.server(), term() | (term() -> boolean())) :: :ok
```

**Examples**:
```elixir
# Exact match
assert_genserver_state(server, %{counter: 5})

# Function validation
assert_genserver_state(server, fn state ->
  state.counter > 0 and state.status == :active
end)
```

#### assert_genserver_responsive/1

```elixir
@spec assert_genserver_responsive(GenServer.server()) :: :ok
```

#### assert_child_count/2

```elixir
@spec assert_child_count(Supervisor.supervisor(), non_neg_integer()) :: :ok
```

**Example**:
```elixir
assert_child_count(supervisor, 5)
```

#### assert_all_children_alive/1

```elixir
@spec assert_all_children_alive(Supervisor.supervisor()) :: :ok
```

#### assert_no_process_leaks/1

```elixir
@spec assert_no_process_leaks((() -> any())) :: :ok
```

**Example**:
```elixir
assert_no_process_leaks(fn ->
  {:ok, temp_server} = GenServer.start_link(TempServer, [])
  # Do work
  GenServer.stop(temp_server)
end)
```

#### assert_memory_usage_stable/2

```elixir
@spec assert_memory_usage_stable((() -> any()), float()) :: :ok
```

**Example**:
```elixir
assert_memory_usage_stable(fn ->
  for _ <- 1..1000 do
    GenServer.call(server, :operation)
  end
end, 0.05)  # 5% tolerance
```

---

## Quick Reference

### Common Patterns

#### Pattern 1: Basic GenServer Test

```elixir
test "counter increments" do
  {:ok, counter} = setup_isolated_genserver(Counter)

  :ok = cast_and_sync(counter, :increment)
  :ok = cast_and_sync(counter, :increment)

  assert_genserver_state(counter, fn s -> s.count == 2 end)
end
```

#### Pattern 2: Supervision Tree Test

```elixir
test "supervisor restarts failed children" do
  {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

  result = test_restart_strategy(supervisor, :one_for_one,
    {:kill_child, :worker_1}
  )

  assert :worker_1 in result.restarted
  wait_for_supervisor_stabilization(supervisor)
  assert_all_children_alive(supervisor)
end
```

#### Pattern 3: Chaos Testing

```elixir
test "system is resilient" do
  {:ok, system} = setup_isolated_supervisor(MySystem)

  report = chaos_kill_children(system,
    kill_rate: 0.5,
    duration_ms: 5000
  )

  assert Process.alive?(system)
  assert report.supervisor_crashed == false
end
```

#### Pattern 4: Performance SLA

```elixir
test "meets performance requirements" do
  {:ok, api} = setup_isolated_genserver(APIServer)

  assert_performance(
    fn -> APIServer.critical_operation(api) end,
    max_time_ms: 100,
    max_memory_bytes: 1_000_000
  )
end
```

#### Pattern 5: Memory Leak Detection

```elixir
test "no memory leak" do
  {:ok, worker} = setup_isolated_genserver(Worker)

  assert_no_memory_leak(50_000, fn ->
    Worker.process(worker, data())
  end)
end
```

### Import Patterns

```elixir
# Core OTP testing
import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

# Supervision testing
import Supertester.{OTPHelpers, SupervisorHelpers, Assertions}

# Chaos testing
import Supertester.{ChaosHelpers, SupervisorHelpers}

# Performance testing
import Supertester.PerformanceHelpers

# Everything
import Supertester.{
  OTPHelpers,
  GenServerHelpers,
  SupervisorHelpers,
  ChaosHelpers,
  PerformanceHelpers,
  Assertions
}
```

### TestableGenServer Pattern

```elixir
# In your GenServer
defmodule MyServer do
  use GenServer
  use Supertester.TestableGenServer  # Add this line

  # Rest of implementation
end

# In your tests
test "with sync" do
  GenServer.cast(server, :async_op)
  GenServer.call(server, :__supertester_sync__)  # Wait for processing
  # Now safe to assert
end
```

---

## Best Practices

### 1. Always Use Isolation

```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Use setup_isolated_* Functions

```elixir
setup do
  {:ok, server} = setup_isolated_genserver(MyServer)
  {:ok, server: server}
end
```

### 3. Never Use Process.sleep

```elixir
# ❌ Bad
GenServer.cast(server, :op)
Process.sleep(50)

# ✅ Good
cast_and_sync(server, :op)
```

### 4. Use Expressive Assertions

```elixir
# ❌ Verbose
state = :sys.get_state(server)
assert state.counter == 5

# ✅ Better
assert_genserver_state(server, %{counter: 5})

# ✅ Best (with validation)
assert_genserver_state(server, fn s -> s.counter == 5 and s.status == :active end)
```

### 5. Test Resilience with Chaos

```elixir
test "system handles chaos" do
  {:ok, system} = setup_isolated_supervisor(MySystem)

  assert_chaos_resilient(system,
    fn -> chaos_kill_children(system, kill_rate: 0.3) end,
    fn -> system_healthy?(system) end
  )
end
```

### 6. Assert Performance SLAs

```elixir
test "meets SLA" do
  assert_performance(
    fn -> critical_path() end,
    max_time_ms: 100
  )
end
```

---

## Testing Supertester Tests

When writing tests for code that uses Supertester:

```elixir
defmodule MyApp.MyModuleTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, Assertions}

  describe "my functionality" do
    test "works correctly" do
      {:ok, server} = setup_isolated_genserver(MyModule)

      # Your test logic
      assert_genserver_responsive(server)
    end
  end
end
```

---

## Migration from Process.sleep

### Before
```elixir
test "async operation" do
  GenServer.cast(server, :operation)
  Process.sleep(50)  # Hope this is enough!
  assert :sys.get_state(server).done == true
end
```

### After
```elixir
test "async operation" do
  :ok = cast_and_sync(server, :operation)
  assert_genserver_state(server, fn s -> s.done == true end)
end
```

---

## Troubleshooting

### Q: Tests are still flaky
**A**: Ensure you're using `cast_and_sync` instead of `GenServer.cast` + sleep

### Q: Name conflicts in tests
**A**: Use `setup_isolated_genserver` which generates unique names

### Q: Supervisor tests fail
**A**: Use `wait_for_supervisor_stabilization` after causing failures

### Q: Performance tests are inconsistent
**A**: Run with `:erlang.garbage_collect()` before measurements, use sufficient iterations

### Q: Chaos tests too aggressive
**A**: Reduce `kill_rate` or `duration_ms` parameters

---

## See Also

- [Technical Design Document](docs/technical-design-enhancement-20251007.md)
- [Implementation Status](docs/implementation-status-final.md)
- [CHANGELOG](CHANGELOG.md)
- [HexDocs](https://hexdocs.pm/supertester)

---

**Version**: 0.2.0
**License**: MIT
**Maintainer**: nshkrdotcom
