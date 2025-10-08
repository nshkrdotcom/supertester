# Supertester Technical Design Enhancement
**Version**: 1.0
**Date**: October 7, 2025
**Status**: DRAFT - Technical Design Document

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State Analysis](#current-state-analysis)
3. [Architecture Overview](#architecture-overview)
4. [Module Design Specifications](#module-design-specifications)
5. [Implementation Roadmap](#implementation-roadmap)
6. [API Reference](#api-reference)
7. [Integration Patterns](#integration-patterns)
8. [Performance Considerations](#performance-considerations)
9. [Testing Strategy](#testing-strategy)
10. [Migration Guide](#migration-guide)

---

## Executive Summary

### Vision
Transform Supertester from a solid OTP testing foundation into **the definitive testing library for fault-tolerant Elixir systems** by adding property-based testing, chaos engineering, distributed testing, and performance regression detection.

### Goals
1. **Differentiation**: Be the only library combining OTP isolation + property testing + chaos engineering
2. **Completeness**: Implement all modules mentioned in documentation
3. **Innovation**: Provide capabilities not available elsewhere in the ecosystem
4. **Production-Ready**: Zero `Process.sleep`, comprehensive error handling, telemetry integration

### Success Metrics
- Zero test failures across 6 target repositories (arsenal, apex, apex_ui, arsenal_plug, sandbox, cluster_test)
- All tests use `async: true` with proper isolation
- Test execution under 30 seconds per repository
- 100% elimination of `Process.sleep/1` in test code
- Property-based tests catch edge cases not found by example tests
- Chaos tests validate resilience assumptions

---

## Current State Analysis

### Existing Modules (Implemented)

#### ✅ `Supertester.UnifiedTestFoundation`
- **Purpose**: Multi-level test isolation
- **Isolation Modes**: `:basic`, `:registry`, `:full_isolation`, `:contamination_detection`
- **Strengths**: Comprehensive cleanup, process tracking, ETS table management
- **Issues**: Uses `Process.sleep(10)` in supervisor waiting (line 279)

#### ✅ `Supertester.OTPHelpers`
- **Purpose**: OTP-compliant testing utilities
- **Key Functions**: `setup_isolated_genserver/3`, `setup_isolated_supervisor/3`, `wait_for_genserver_sync/2`
- **Strengths**: Unique naming, automatic cleanup, process lifecycle management
- **Issues**: Uses `Process.sleep(5)` in restart loops (lines 344, 349)

#### ✅ `Supertester.GenServerHelpers`
- **Purpose**: GenServer-specific testing patterns
- **Key Functions**: `cast_and_sync/3`, `get_server_state_safely/1`, `concurrent_calls/3`, `stress_test_server/3`
- **Strengths**: Comprehensive GenServer testing utilities, concurrent testing support
- **Issues**: Uses `Process.sleep(10)` in recovery loops (lines 389, 403)

#### ✅ `Supertester.Assertions`
- **Purpose**: OTP-aware custom assertions
- **Key Functions**: `assert_process_alive/1`, `assert_genserver_state/2`, `assert_no_process_leaks/1`
- **Strengths**: Expressive, meaningful error messages
- **Issues**: Uses `Process.sleep(10)` in leak detection (line 322)

### Missing Modules (Documented but Not Implemented)

#### ❌ `Supertester.SupervisorHelpers`
**Status**: Mentioned in main module docs, not implemented
**Priority**: HIGH - Core OTP functionality

#### ❌ `Supertester.MessageHelpers`
**Status**: Mentioned in main module docs, not implemented
**Priority**: MEDIUM - Debugging and tracing

#### ❌ `Supertester.PerformanceHelpers`
**Status**: Mentioned in main module docs, not implemented
**Priority**: HIGH - CI/CD integration need

#### ❌ `Supertester.ChaosHelpers`
**Status**: Mentioned in main module docs, not implemented
**Priority**: CRITICAL - Major differentiator

#### ❌ `Supertester.DataGenerators`
**Status**: Mentioned in main module docs, not implemented
**Priority**: MEDIUM - Supports property testing

#### ❌ `Supertester.PropertyHelpers`
**Status**: Not mentioned, but critical innovation opportunity
**Priority**: CRITICAL - Ecosystem differentiation

#### ❌ `Supertester.DistributedHelpers`
**Status**: Not mentioned, but essential for multi-repo vision
**Priority**: HIGH - Matches monorepo architecture

---

## Architecture Overview

### Layered Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User Test Code                            │
├─────────────────────────────────────────────────────────────┤
│  Property Testing │ Chaos Testing │ Performance Testing     │
│  (PropertyHelpers)│ (ChaosHelpers)│ (PerformanceHelpers)   │
├─────────────────────────────────────────────────────────────┤
│   OTP Helpers     │ GenServer     │ Supervisor    │ Message │
│   (Basic Patterns)│ (Specialized) │ (Tree Testing)│ (Debug) │
├─────────────────────────────────────────────────────────────┤
│         Distributed Testing (DistributedHelpers)             │
├─────────────────────────────────────────────────────────────┤
│              Unified Test Foundation (Isolation)             │
├─────────────────────────────────────────────────────────────┤
│                   ExUnit + StreamData                        │
└─────────────────────────────────────────────────────────────┘
```

### Dependency Graph

```
PropertyHelpers ──┬──> OTPHelpers
                  ├──> GenServerHelpers
                  ├──> SupervisorHelpers
                  └──> StreamData (external)

ChaosHelpers ─────┬──> OTPHelpers
                  ├──> SupervisorHelpers
                  └──> MessageHelpers

PerformanceHelpers ─> Benchee (external)
                    └─> OTPHelpers

DistributedHelpers ─> LocalCluster (external)
                    ├─> OTPHelpers
                    └─> GenServerHelpers

All modules ──────> UnifiedTestFoundation
```

### Core Design Principles

1. **Zero Process.sleep**: All synchronization via OTP primitives (monitors, refs, calls)
2. **Composability**: Modules work independently and in combination
3. **Telemetry**: All operations emit telemetry events for observability
4. **Graceful Degradation**: Missing dependencies disable features, not crash
5. **Test Isolation**: All helpers respect and enhance isolation modes
6. **Documentation First**: Every function has doctests and examples

---

## Module Design Specifications

### 1. `Supertester.PropertyHelpers`

**Status**: NEW - Critical Innovation
**Dependencies**: `StreamData`, `ExUnitProperties`

#### Purpose
Provide OTP-aware generators for property-based testing of concurrent systems.

#### Core Functions

##### `genserver_operation_sequence/2`
```elixir
@spec genserver_operation_sequence(operations :: [atom() | tuple()], opts :: keyword()) ::
        StreamData.t([operation()])

@doc """
Generates sequences of GenServer operations for property testing.

## Options

- `:max_length` - Maximum sequence length (default: 50)
- `:min_length` - Minimum sequence length (default: 1)
- `:weights` - Operation probability weights (default: equal)

## Examples

    property "counter invariants hold" do
      check all operations <- genserver_operation_sequence(
        [:increment, :decrement, {:add, integer()}, :reset],
        max_length: 100
      ) do
        {:ok, counter} = setup_isolated_genserver(Counter)

        Enum.each(operations, fn op ->
          apply_operation(counter, op)
        end)

        {:ok, value} = Counter.get(counter)
        assert value >= 0  # Invariant: never negative
      end
    end

## Generated Values

Returns StreamData generator producing lists of operations.
Operations can be atoms or tuples with generated parameters.
"""
```

**Implementation Notes**:
- Use `StreamData.list_of/2` with length constraints
- Support weighted operation selection via `StreamData.frequency/1`
- Generate parameters for tuple operations using nested generators
- Shrinking should reduce both sequence length and parameter complexity

##### `concurrent_scenario/1`
```elixir
@spec concurrent_scenario(opts :: keyword()) :: StreamData.t(concurrent_scenario())

@typedoc """
A concurrent test scenario.

- `:num_processes` - Number of concurrent processes
- `:operations` - List of operation lists, one per process
- `:timing` - Optional timing constraints
"""
@type concurrent_scenario :: %{
  num_processes: pos_integer(),
  operations: [[operation()]],
  timing: nil | timing_constraints()
}

@doc """
Generates concurrent operation scenarios for race condition testing.

## Options

- `:operations` - List of valid operations (required)
- `:processes` - Range of concurrent processes (default: 2..10)
- `:operations_per_process` - Range of operations per process (default: 1..20)
- `:synchronized_start` - Whether all processes start simultaneously (default: false)

## Examples

    property "concurrent access preserves consistency" do
      check all scenario <- concurrent_scenario(
        operations: [:increment, :decrement],
        processes: 5..20,
        operations_per_process: 10..50
      ) do
        {:ok, counter} = setup_isolated_genserver(Counter)

        results = execute_concurrent_scenario(counter, scenario)

        # Verify all operations succeeded
        assert Enum.all?(results, &match?({:ok, _}, &1))

        # Verify consistency
        {:ok, final} = Counter.get(counter)
        expected = calculate_expected(scenario)
        assert final == expected
      end
    end
"""
```

**Implementation Strategy**:
1. Generate number of processes from range
2. For each process, generate operation sequence
3. Optionally generate timing constraints (delays, barriers)
4. Provide helper `execute_concurrent_scenario/2` for running

##### `supervisor_config/1`
```elixir
@spec supervisor_config(opts :: keyword()) :: StreamData.t(supervisor_config())

@type supervisor_config :: %{
  strategy: :one_for_one | :one_for_all | :rest_for_one,
  num_children: pos_integer(),
  max_restarts: non_neg_integer(),
  max_seconds: pos_integer(),
  child_specs: [child_spec_config()]
}

@doc """
Generates valid supervision tree configurations for testing.

## Options

- `:strategies` - List of strategies to test (default: all)
- `:children` - Range of child count (default: 1..5)
- `:max_restarts` - Range of max_restarts (default: 1..10)
- `:child_restart_types` - List of restart types (default: [:permanent, :temporary, :transient])

## Examples

    property "supervisor recovers from any child crash" do
      check all config <- supervisor_config(
        strategies: [:one_for_one, :one_for_all],
        children: 2..5
      ) do
        {:ok, supervisor} = start_test_supervisor(config)

        # Kill random child
        children = Supervisor.which_children(supervisor)
        {_id, pid, _type, _modules} = Enum.random(children)
        Process.exit(pid, :kill)

        # Verify recovery based on strategy
        wait_for_supervisor_stabilization(supervisor)
        verify_supervisor_state(supervisor, config)
      end
    end
"""
```

##### `message_sequence/1`
```elixir
@spec message_sequence(opts :: keyword()) :: StreamData.t([message()])

@doc """
Generates sequences of messages respecting protocol constraints.

## Options

- `:valid_messages` - List of valid message patterns (required)
- `:constraints` - List of ordering/dependency constraints (default: [])
- `:max_length` - Maximum sequence length (default: 20)

## Constraints

Constraints can be:
- `{:requires, message_type, prerequisite_type}` - message requires another first
- `{:once, message_type}` - message can only appear once
- `{:terminal, message_type}` - message must be last if present
- `{:excludes, message_type, excluded_type}` - messages are mutually exclusive

## Examples

    property "protocol handles all valid sequences" do
      check all sequence <- message_sequence(
        valid_messages: [
          {:connect, binary()},
          {:authenticate, binary()},
          {:send, binary()},
          :disconnect
        ],
        constraints: [
          {:requires, :send, :connect},
          {:requires, :send, :authenticate},
          {:terminal, :disconnect},
          {:once, :connect}
        ]
      ) do
        {:ok, protocol} = setup_isolated_genserver(ProtocolServer)

        Enum.each(sequence, fn msg ->
          assert {:ok, _} = GenServer.call(protocol, msg)
        end)
      end
    end
"""
```

**Implementation Challenge**: Constraint-satisfying sequence generation
- Use recursive generation with state tracking
- Filter invalid sequences (may be slow)
- Or use constraint solver approach

##### `chaos_scenario/1`
```elixir
@spec chaos_scenario(opts :: keyword()) :: StreamData.t(chaos_scenario())

@type chaos_scenario :: %{
  duration_ms: pos_integer(),
  events: [chaos_event()],
  intensity: :low | :medium | :high
}

@type chaos_event ::
  {:crash_process, pid() | atom()} |
  {:delay_messages, milliseconds :: pos_integer()} |
  {:drop_messages, probability :: float()} |
  {:partition_network, nodes :: [node()]} |
  {:exhaust_resource, resource :: atom()}

@doc """
Generates chaos engineering scenarios for resilience testing.

## Options

- `:events` - List of chaos event types to include (required)
- `:intensity` - How aggressive the chaos is (default: :medium)
- `:duration` - Range of scenario duration in ms (default: 1000..5000)
- `:event_rate` - Events per second range (default: 1..10)

## Examples

    property "system recovers from chaos" do
      check all chaos <- chaos_scenario(
        events: [:crash_process, :delay_messages, :partition_network],
        intensity: :medium,
        duration: 2000..5000
      ) do
        {:ok, system} = start_supervised(MySystem)

        # Record initial state
        initial_state = capture_system_state(system)

        # Apply chaos
        apply_chaos_scenario(system, chaos)

        # Verify recovery
        assert_eventually(fn ->
          system_healthy?(system) and
          state_consistent?(system, initial_state)
        end, timeout: 10_000)
      end
    end
"""
```

#### Module Structure

```elixir
defmodule Supertester.PropertyHelpers do
  @moduledoc """
  Property-based testing helpers for OTP systems.

  This module provides StreamData generators designed specifically for
  testing concurrent OTP applications with property-based testing.
  """

  use ExUnitProperties
  import StreamData

  # Re-export commonly used StreamData functions for convenience
  defdelegate integer(range), to: StreamData
  defdelegate binary(), to: StreamData
  defdelegate atom(type), to: StreamData

  # Generator functions (as documented above)

  # Execution helpers
  def execute_concurrent_scenario(server, scenario)
  def execute_operation_sequence(server, operations)
  def apply_chaos_scenario(system, scenario)

  # Verification helpers
  def verify_genserver_invariants(server, invariant_fn)
  def verify_supervisor_state(supervisor, expected_config)
  def calculate_expected_state(scenario)
end
```

#### Testing Strategy

The module itself needs comprehensive tests:
1. Generator tests (verify valid output)
2. Shrinking tests (verify minimal failing cases)
3. Integration tests with actual GenServers
4. Performance tests (generation speed)

---

### 2. `Supertester.ChaosHelpers`

**Status**: NEW - Critical Differentiator
**Dependencies**: `Supertester.OTPHelpers`, `Supertester.SupervisorHelpers`

#### Purpose
Chaos engineering toolkit for testing fault tolerance and resilience in OTP systems.

#### Core Functions

##### `inject_crash/3`
```elixir
@spec inject_crash(target :: pid() | atom(), crash_spec :: crash_spec(), opts :: keyword()) ::
        :ok

@type crash_spec ::
  {:random, probability :: float()} |
  {:after_calls, count :: pos_integer()} |
  {:on_message, message_pattern :: term()} |
  {:periodic, interval_ms :: pos_integer()}

@doc """
Injects controlled crashes into a process for resilience testing.

## Options

- `:reason` - Exit reason (default: `:chaos_injection`)
- `:monitor` - Whether to monitor the crash (default: true)
- `:verify_restart` - Assert process restarts (default: false)

## Examples

    test "system handles random worker crashes" do
      {:ok, supervisor} = setup_isolated_supervisor(WorkerSupervisor)
      workers = get_worker_pids(supervisor)

      # Crash random worker 30% of the time
      inject_crash(Enum.random(workers), {:random, 0.3})

      # Run operations
      perform_work(supervisor, 1000)

      # Verify system still functioning
      assert_all_children_alive(supervisor)
    end
"""
```

**Implementation Notes**:
- Use `:sys.replace_state/2` or `:sys.install/2` for interception
- Track injection statistics for reporting
- Emit telemetry events: `[:supertester, :chaos, :crash_injected]`

##### `chaos_kill_children/3`
```elixir
@spec chaos_kill_children(supervisor :: pid(), opts :: keyword()) :: chaos_report()

@type chaos_report :: %{
  killed: non_neg_integer(),
  restarted: non_neg_integer(),
  failed_to_restart: non_neg_integer(),
  supervisor_crashed: boolean()
}

@doc """
Randomly kills children in a supervision tree to test restart strategies.

## Options

- `:kill_rate` - Percentage of children to kill (default: 0.3 = 30%)
- `:duration_ms` - How long to run chaos (default: 5000)
- `:kill_interval_ms` - Time between kills (default: 100)
- `:kill_reason` - Reason for kills (default: :kill)

## Examples

    test "supervisor handles cascading failures" do
      {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

      report = chaos_kill_children(supervisor,
        kill_rate: 0.5,
        duration_ms: 3000,
        kill_interval_ms: 200
      )

      # Verify supervisor survived
      assert Process.alive?(supervisor)
      assert report.supervisor_crashed == false

      # Verify recovery
      assert_all_children_alive(supervisor)
    end
"""
```

##### `simulate_resource_exhaustion/2`
```elixir
@spec simulate_resource_exhaustion(resource :: resource_type(), opts :: keyword()) ::
        {:ok, cleanup_fn :: (() -> :ok)} | {:error, term()}

@type resource_type ::
  :process_limit |
  :port_limit |
  :ets_tables |
  :memory |
  :atoms

@doc """
Simulates resource exhaustion scenarios.

## Options

- `:percentage` - Percentage of limit to consume (default: 0.8 = 80%)
- `:gradual` - Gradually increase pressure (default: false)
- `:duration_ms` - How long to maintain pressure (default: 5000)

## Examples

    test "system handles process limit pressure" do
      test_fn = fn ->
        {:ok, cleanup} = simulate_resource_exhaustion(:process_limit,
          percentage: 0.9,
          duration_ms: 3000
        )

        # Try to perform operations under pressure
        result = perform_critical_operation()

        # Cleanup
        cleanup.()

        # Verify graceful degradation
        assert match?({:error, :system_overload}, result)
      end

      assert_no_process_leaks(test_fn)
    end
"""
```

**Implementation Strategy**:
- Spawn processes up to limit
- Track all spawned resources
- Provide cleanup function
- Monitor for system stability

##### `chaos_message_delivery/2`
```elixir
@spec chaos_message_delivery(target :: pid(), opts :: keyword()) ::
        {:ok, restore_fn :: (() -> :ok)}

@doc """
Introduces message delivery chaos (delays, drops, reordering).

## Options

- `:delay_range_ms` - Range for message delays (default: 0..100)
- `:drop_probability` - Probability of dropping messages (default: 0.0)
- `:reorder_probability` - Probability of reordering (default: 0.0)

## Examples

    test "protocol handles message delays and reordering" do
      {:ok, protocol} = setup_isolated_genserver(ProtocolServer)

      {:ok, restore} = chaos_message_delivery(protocol,
        delay_range_ms: 10..500,
        reorder_probability: 0.2
      )

      # Send messages that should be ordered
      send_protocol_sequence(protocol, [:connect, :auth, :send, :disconnect])

      # Verify protocol handles chaos gracefully
      assert_eventually(fn ->
        protocol_state(protocol) == :disconnected
      end)

      restore.()
    end
"""
```

**Implementation Approach**:
- Intercept message queue using `:sys.install/2`
- Buffer messages and apply chaos transformations
- Restore original behavior with cleanup function

##### `run_chaos_suite/3`
```elixir
@spec run_chaos_suite(target :: pid() | atom(), scenarios :: [chaos_scenario()], opts :: keyword()) ::
        chaos_suite_report()

@type chaos_suite_report :: %{
  total_scenarios: non_neg_integer(),
  passed: non_neg_integer(),
  failed: non_neg_integer(),
  failures: [failure_report()],
  duration_ms: non_neg_integer()
}

@doc """
Runs a comprehensive chaos testing suite.

## Examples

    test "system passes chaos gauntlet" do
      {:ok, system} = start_supervised(MySystem)

      scenarios = [
        %{type: :crash_process, intensity: :low},
        %{type: :message_delay, intensity: :medium},
        %{type: :resource_exhaustion, resource: :process_limit},
        %{type: :network_partition, nodes: [:node1, :node2]}
      ]

      report = run_chaos_suite(system, scenarios, timeout: 30_000)

      assert report.passed == report.total_scenarios
      assert report.failed == 0
    end
"""
```

#### Module Structure

```elixir
defmodule Supertester.ChaosHelpers do
  @moduledoc """
  Chaos engineering toolkit for OTP resilience testing.

  Provides controlled fault injection to verify system fault tolerance,
  recovery mechanisms, and graceful degradation under adverse conditions.
  """

  require Logger
  alias Supertester.{OTPHelpers, SupervisorHelpers}

  # Crash injection
  def inject_crash(target, crash_spec, opts \\ [])

  # Supervisor chaos
  def chaos_kill_children(supervisor, opts \\ [])
  def chaos_supervisor_tree(root_supervisor, opts \\ [])

  # Resource exhaustion
  def simulate_resource_exhaustion(resource, opts \\ [])
  def exhaust_process_limit(percentage)
  def exhaust_ets_tables(percentage)

  # Message chaos
  def chaos_message_delivery(target, opts \\ [])
  def drop_messages(target, probability)
  def delay_messages(target, delay_range)
  def reorder_messages(target, probability)

  # Comprehensive chaos
  def run_chaos_suite(target, scenarios, opts \\ [])

  # Verification helpers
  def assert_chaos_resilient(target, chaos_fn, recovery_fn, opts \\ [])
  def assert_recovers_within(target, chaos_fn, timeout_ms)

  # Telemetry
  defp emit_chaos_event(event, metadata)

  # Private implementation
  defp spawn_resource_consumers(resource, count)
  defp cleanup_resources(resources)
end
```

#### Telemetry Events

```elixir
# Event: [:supertester, :chaos, :crash_injected]
# Metadata: %{target: pid, reason: atom, timestamp: integer}

# Event: [:supertester, :chaos, :child_killed]
# Metadata: %{supervisor: pid, child: pid, restart_result: atom}

# Event: [:supertester, :chaos, :resource_exhaustion]
# Metadata: %{resource: atom, consumed: integer, limit: integer}

# Event: [:supertester, :chaos, :message_chaos]
# Metadata: %{type: atom, target: pid, message: term}
```

---

### 3. `Supertester.PerformanceHelpers`

**Status**: NEW - High Priority
**Dependencies**: `Benchee`, `Supertester.OTPHelpers`

#### Purpose
Performance benchmarking and regression detection integrated with test isolation.

#### Core Functions

##### `benchmark_isolated/3`
```elixir
@spec benchmark_isolated(name :: String.t(), functions :: map(), opts :: keyword()) ::
        Benchee.Suite.t()

@doc """
Runs Benchee benchmarks with Supertester isolation.

## Options

Standard Benchee options plus:
- `:isolation` - Isolation mode (default: :full_isolation)
- `:export_path` - Path to save results for regression testing
- `:baseline_path` - Path to baseline for comparison

## Examples

    test "benchmark counter operations", %{isolation_context: context} do
      benchmark_isolated("counter_ops", %{
        "increment" => fn counter -> Counter.increment(counter) end,
        "decrement" => fn counter -> Counter.decrement(counter) end,
        "get" => fn counter -> Counter.get(counter) end
      },
        isolation: :full_isolation,
        setup: fn ->
          {:ok, counter} = setup_isolated_genserver(Counter)
          counter
        end,
        time: 5,
        memory_time: 2
      )
    end
"""
```

##### `assert_performance/2`
```elixir
@spec assert_performance(operation :: (() -> any()), expectations :: keyword()) :: :ok

@doc """
Asserts operation meets performance expectations.

## Expectations

- `:max_time_ms` - Maximum execution time in milliseconds
- `:max_memory_bytes` - Maximum memory consumption
- `:max_reductions` - Maximum reductions (CPU work)

## Examples

    test "critical path performance" do
      {:ok, server} = setup_isolated_genserver(CriticalServer)

      assert_performance(
        fn -> CriticalServer.critical_operation(server) end,
        max_time_ms: 100,
        max_memory_bytes: 1_000_000,
        max_reductions: 100_000
      )
    end
"""
```

##### `assert_no_memory_leak/2`
```elixir
@spec assert_no_memory_leak(iterations :: pos_integer(), operation :: (() -> any())) :: :ok

@doc """
Verifies operation doesn't leak memory over many iterations.

## Examples

    test "no memory leak in message handling" do
      {:ok, server} = setup_isolated_genserver(MessageHandler)

      assert_no_memory_leak(10_000, fn ->
        MessageHandler.handle_message(server, {:data, random_data(1024)})
      end)
    end
"""
```

**Implementation**:
- Measure memory before/after with `:erlang.memory()`
- Force GC between measurements
- Allow small growth (threshold) but detect unbounded growth
- Use linear regression to detect memory trend

##### `assert_no_regression/2`
```elixir
@spec assert_no_regression(benchmark_name :: String.t(), baseline_path :: String.t()) :: :ok

@doc """
Compares benchmark results against a baseline to detect regressions.

## Examples

    test "performance regression check" do
      results = benchmark_isolated("api_performance", %{
        "list_users" => fn -> API.list_users() end,
        "create_user" => fn -> API.create_user(user_params()) end
      }, export_path: "tmp/current_benchmark.json")

      assert_no_regression("api_performance", "test/fixtures/baseline_benchmark.json")
    end
"""
```

**Regression Detection Algorithm**:
- Load baseline results
- Compare median times
- Flag if current > baseline * threshold (e.g., 1.1 = 10% slower)
- Generate detailed report

##### `measure_scheduler_utilization/1`
```elixir
@spec measure_scheduler_utilization(operation :: (() -> any())) :: utilization_report()

@type utilization_report :: %{
  wall_time_ms: float(),
  scheduler_usage: [float()],
  total_reductions: non_neg_integer(),
  process_count: non_neg_integer()
}

@doc """
Measures scheduler utilization during operation.

## Examples

    test "operation utilizes all schedulers" do
      report = measure_scheduler_utilization(fn ->
        perform_parallel_work(10_000)
      end)

      # Verify good parallelization
      avg_utilization = Enum.sum(report.scheduler_usage) / length(report.scheduler_usage)
      assert avg_utilization > 0.7  # >70% average utilization
    end
"""
```

##### `assert_mailbox_stable/2`
```elixir
@spec assert_mailbox_stable(server :: pid(), opts :: keyword()) :: :ok

@doc """
Asserts GenServer mailbox doesn't grow unbounded during operation.

## Options

- `:during` - Function to execute while monitoring (required)
- `:max_size` - Maximum mailbox size allowed (default: 100)
- `:sample_interval_ms` - Sampling interval (default: 10)

## Examples

    test "mailbox doesn't grow under load" do
      {:ok, server} = setup_isolated_genserver(Worker)

      assert_mailbox_stable(server,
        during: fn ->
          Enum.each(1..10_000, fn i ->
            GenServer.cast(server, {:work, i})
          end)
        end,
        max_size: 50
      )
    end
"""
```

#### Module Structure

```elixir
defmodule Supertester.PerformanceHelpers do
  @moduledoc """
  Performance testing and regression detection for OTP systems.

  Integrates Benchee with Supertester's isolation patterns and provides
  performance assertions for CI/CD pipelines.
  """

  alias Supertester.OTPHelpers

  # Benchmarking
  def benchmark_isolated(name, functions, opts \\ [])

  # Assertions
  def assert_performance(operation, expectations)
  def assert_no_memory_leak(iterations, operation)
  def assert_no_regression(benchmark_name, baseline_path)
  def assert_mailbox_stable(server, opts)

  # Measurements
  def measure_operation(operation)
  def measure_memory_usage(operation)
  def measure_scheduler_utilization(operation)
  def measure_mailbox_growth(server, during)

  # Regression testing
  def export_benchmark(results, path)
  def load_baseline(path)
  def compare_results(current, baseline)

  # Private
  defp force_gc()
  defp measure_with_gc(operation)
  defp detect_memory_trend(measurements)
end
```

---

### 4. `Supertester.DistributedHelpers`

**Status**: NEW - High Priority
**Dependencies**: `LocalCluster` (optional), `Supertester.OTPHelpers`

#### Purpose
Multi-node testing for distributed Elixir systems.

#### Core Functions

##### `setup_test_cluster/1`
```elixir
@spec setup_test_cluster(opts :: keyword()) ::
        {:ok, cluster_info()} | {:error, term()}

@type cluster_info :: %{
  nodes: [node()],
  cleanup: (() -> :ok)
}

@doc """
Sets up an isolated test cluster for distributed testing.

## Options

- `:nodes` - Number of nodes (default: 2)
- `:isolation` - Isolation mode per node (default: :full_isolation)
- `:connect` - Auto-connect nodes (default: true)

## Examples

    test "distributed GenServer works across nodes" do
      {:ok, cluster} = setup_test_cluster(nodes: 3)

      # Start GenServer on first node
      [node1, node2, node3] = cluster.nodes
      {:ok, server} = :rpc.call(node1, GenServer, :start_link, [MyServer, [], [name: MyServer]])

      # Call from other nodes
      assert {:ok, _} = :rpc.call(node2, GenServer, :call, [{MyServer, node1}, :ping])
      assert {:ok, _} = :rpc.call(node3, GenServer, :call, [{MyServer, node1}, :ping])

      cluster.cleanup.()
    end
"""
```

##### `test_distributed_genserver/2`
```elixir
@spec test_distributed_genserver(module :: module(), scenarios :: [dist_scenario()]) ::
        test_report()

@type dist_scenario ::
  {:start_on, node()} |
  {:call_from, node(), message :: term()} |
  {:partition, [node()], [node()]} |
  {:heal_partition}

@doc """
Tests GenServer behavior in distributed scenarios.

## Examples

    test "GenServer handles network partitions" do
      report = test_distributed_genserver(MyDistServer, [
        {:start_on, :node1},
        {:call_from, :node2, :get_state},
        {:partition, [:node1], [:node2, :node3]},
        {:call_from, :node2, :get_state},  # Should handle partition
        {:heal_partition},
        {:call_from, :node2, :sync_state}  # Should sync
      ])

      assert report.all_scenarios_passed
    end
"""
```

##### `simulate_partition/3`
```elixir
@spec simulate_partition(nodes_a :: [node()], nodes_b :: [node()], opts :: keyword()) ::
        {:ok, heal_fn :: (() -> :ok)}

@doc """
Simulates network partition between node groups.

## Options

- `:duration_ms` - Auto-heal after duration (default: :infinity)

## Examples

    test "system handles network partition" do
      {:ok, cluster} = setup_test_cluster(nodes: 4)
      [n1, n2, n3, n4] = cluster.nodes

      # Partition into two groups
      {:ok, heal} = simulate_partition([n1, n2], [n3, n4])

      # Verify split-brain handling
      verify_partition_behavior([n1, n2], [n3, n4])

      # Heal partition
      heal.()

      # Verify convergence
      assert_eventually(fn ->
        states_converged?(cluster.nodes)
      end)
    end
"""
```

##### `assert_eventually_consistent/3`
```elixir
@spec assert_eventually_consistent(nodes :: [node()], state_fn :: (node() -> term()), opts :: keyword()) ::
        :ok

@doc """
Asserts distributed state becomes eventually consistent.

## Options

- `:timeout_ms` - Maximum time to wait (default: 5000)
- `:check_interval_ms` - How often to check (default: 100)

## Examples

    test "distributed cache becomes consistent" do
      {:ok, cluster} = setup_test_cluster(nodes: 3)

      # Start cache on all nodes
      Enum.each(cluster.nodes, fn node ->
        :rpc.call(node, DistributedCache, :start_link, [])
      end)

      # Write to one node
      :rpc.call(hd(cluster.nodes), DistributedCache, :put, [:key, :value])

      # Assert all nodes eventually see it
      assert_eventually_consistent(cluster.nodes,
        fn node ->
          :rpc.call(node, DistributedCache, :get, [:key])
        end,
        timeout_ms: 3000
      )
    end
"""
```

#### Module Structure

```elixir
defmodule Supertester.DistributedHelpers do
  @moduledoc """
  Multi-node testing utilities for distributed Elixir systems.

  Provides cluster setup, partition simulation, and distributed
  consistency testing.
  """

  # Cluster management
  def setup_test_cluster(opts \\ [])
  def teardown_cluster(cluster_info)

  # Distributed GenServer testing
  def test_distributed_genserver(module, scenarios)
  def start_distributed_server(module, node, opts \\ [])

  # Network simulation
  def simulate_partition(nodes_a, nodes_b, opts \\ [])
  def heal_partition(nodes)
  def simulate_latency(nodes, latency_ms)

  # Consistency testing
  def assert_eventually_consistent(nodes, state_fn, opts \\ [])
  def assert_distributed_state(nodes, expected_state)

  # Verification helpers
  def verify_node_connectivity(nodes)
  def verify_global_registration(name, nodes)

  # Private
  defp start_slave_node(name, opts)
  defp connect_nodes(nodes)
  defp disconnect_nodes(nodes_a, nodes_b)
end
```

---

### 5. `Supertester.SupervisorHelpers`

**Status**: NEW - High Priority (Core OTP)
**Dependencies**: `Supertester.OTPHelpers`

#### Purpose
Specialized testing utilities for supervision trees.

#### Core Functions

##### `test_restart_strategy/3`
```elixir
@spec test_restart_strategy(supervisor :: pid(), strategy :: atom(), scenario :: restart_scenario()) ::
        test_result()

@type restart_scenario ::
  {:kill_child, child_id :: term()} |
  {:kill_children, [child_id :: term()]} |
  {:cascade_failure, start_child_id :: term()}

@doc """
Tests supervisor restart strategies with various failure scenarios.

## Examples

    test "one_for_one restarts only failed child" do
      {:ok, supervisor} = setup_isolated_supervisor(OneSupervisor)

      children_before = Supervisor.which_children(supervisor)

      result = test_restart_strategy(supervisor, :one_for_one,
        {:kill_child, :worker_1}
      )

      assert result.restarted == [:worker_1]
      assert result.not_restarted == [:worker_2, :worker_3]
    end
"""
```

##### `assert_supervision_tree_structure/2`
```elixir
@spec assert_supervision_tree_structure(supervisor :: pid(), expected :: tree_structure()) :: :ok

@type tree_structure :: %{
  supervisor: module(),
  strategy: atom(),
  children: [child_structure()]
}

@type child_structure ::
  {child_id :: term(), module :: module()} |
  {child_id :: term(), tree_structure()}

@doc """
Asserts supervision tree matches expected structure.

## Examples

    test "supervision tree structure" do
      {:ok, root} = setup_isolated_supervisor(RootSupervisor)

      assert_supervision_tree_structure(root, %{
        supervisor: RootSupervisor,
        strategy: :one_for_one,
        children: [
          {:cache, CacheServer},
          {:workers, %{
            supervisor: WorkerSupervisor,
            strategy: :one_for_all,
            children: [
              {:worker_1, Worker},
              {:worker_2, Worker}
            ]
          }}
        ]
      })
    end
"""
```

##### `trace_supervision_events/2`
```elixir
@spec trace_supervision_events(supervisor :: pid(), opts :: keyword()) ::
        {:ok, stop_fn :: (() -> [event()])}

@type event ::
  {:child_started, child_id :: term(), pid()} |
  {:child_terminated, child_id :: term(), pid(), reason :: term()} |
  {:child_restarted, child_id :: term(), old_pid :: pid(), new_pid :: pid()}

@doc """
Traces all supervision events for verification.

## Examples

    test "supervisor restart behavior" do
      {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)
      {:ok, stop_trace} = trace_supervision_events(supervisor)

      # Cause some failures
      children = Supervisor.which_children(supervisor)
      Enum.each(children, fn {_id, pid, _type, _mods} ->
        Process.exit(pid, :kill)
      end)

      # Get events
      events = stop_trace.()

      # Verify restart sequence
      assert length(events) >= 6  # 3 terminates + 3 restarts
      assert Enum.any?(events, &match?({:child_restarted, _, _, _}, &1))
    end
"""
```

---

### 6. `Supertester.MessageHelpers`

**Status**: NEW - Medium Priority
**Dependencies**: None (uses `:sys` module)

#### Purpose
Message tracing and debugging for process communication.

#### Core Functions

##### `trace_messages/2`
```elixir
@spec trace_messages(pid :: pid(), opts :: keyword()) ::
        {:ok, stop_fn :: (() -> [traced_message()])}

@type traced_message :: %{
  direction: :in | :out,
  message: term(),
  timestamp: integer(),
  from: pid() | nil,
  to: pid() | nil
}

@doc """
Traces all messages sent to/from a process.

## Options

- `:filter` - Filter function (default: all messages)
- `:max_messages` - Maximum messages to capture (default: :infinity)

## Examples

    test "verify message flow" do
      {:ok, server} = setup_isolated_genserver(MyServer)
      {:ok, stop} = trace_messages(server)

      # Perform operations
      GenServer.call(server, :operation_1)
      GenServer.cast(server, :operation_2)

      # Analyze messages
      messages = stop.()

      assert length(messages) == 4  # 2 calls (req+resp) + 1 cast
      assert Enum.any?(messages, &match?(%{direction: :in, message: :operation_1}, &1))
    end
"""
```

##### `assert_message_sequence/2`
```elixir
@spec assert_message_sequence(pid :: pid(), expected :: [message_pattern()]) :: :ok

@type message_pattern :: term() | (term() -> boolean())

@doc """
Asserts process receives messages in expected order.

## Examples

    test "protocol message ordering" do
      {:ok, protocol} = setup_isolated_genserver(Protocol)

      Task.async(fn ->
        send(protocol, :connect)
        send(protocol, {:data, "hello"})
        send(protocol, :disconnect)
      end)

      assert_message_sequence(protocol, [
        :connect,
        fn msg -> match?({:data, _}, msg) end,
        :disconnect
      ])
    end
"""
```

##### `detect_deadlock/2`
```elixir
@spec detect_deadlock(pids :: [pid()], timeout :: timeout()) ::
        {:ok, :no_deadlock} | {:error, :deadlock_detected, info :: map()}

@doc """
Detects potential deadlocks in a group of processes.

## Examples

    test "no deadlock in request chain" do
      {:ok, server_a} = setup_isolated_genserver(ServerA)
      {:ok, server_b} = setup_isolated_genserver(ServerB)

      # Setup circular dependency
      ServerA.set_dependency(server_a, server_b)
      ServerB.set_dependency(server_b, server_a)

      # This should detect deadlock
      assert {:error, :deadlock_detected, _} =
        detect_deadlock([server_a, server_b], 1000)
    end
"""
```

---

### 7. `Supertester.ETSHelpers`

**Status**: NEW - Medium-Low Priority
**Dependencies**: `Supertester.OTPHelpers`

#### Core Functions

```elixir
defmodule Supertester.ETSHelpers do
  @moduledoc """
  ETS testing utilities with isolation and race condition detection.
  """

  def setup_isolated_ets(name, options, test_context)
  def assert_ets_contains(table, expected_data)
  def test_concurrent_ets_access(table, operations, num_processes)
  def detect_ets_race_conditions(table, operations)
  def assert_ets_memory_stable(table, during)
end
```

---

## Implementation Roadmap

### Phase 1: Foundation & Critical Gaps (Weeks 1-4)

**Goals**: Implement missing core modules, eliminate Process.sleep

#### Week 1-2: Code Quality & SupervisorHelpers
- [ ] Remove all `Process.sleep` calls, replace with monitor-based patterns
- [ ] Implement `Supertester.SupervisorHelpers` (core OTP functionality)
- [ ] Add `TestableGenServer` behavior for `__supertester_sync__` handling
- [ ] Add comprehensive test coverage for existing modules

#### Week 3-4: ChaosHelpers (Critical Differentiator)
- [ ] Implement basic crash injection (`inject_crash/3`)
- [ ] Implement supervisor chaos (`chaos_kill_children/3`)
- [ ] Implement resource exhaustion simulation
- [ ] Add telemetry events for all chaos operations
- [ ] Write comprehensive documentation with examples

**Deliverables**:
- Zero `Process.sleep` in codebase
- `SupervisorHelpers` module complete
- `ChaosHelpers` v1.0 complete with 80% test coverage
- Updated documentation

---

### Phase 2: Performance & Property Testing (Weeks 5-8)

**Goals**: Add performance testing and begin property-based testing integration

#### Week 5-6: PerformanceHelpers
- [ ] Integrate Benchee with isolation modes
- [ ] Implement `benchmark_isolated/3`
- [ ] Implement performance assertions (`assert_performance/2`)
- [ ] Implement memory leak detection
- [ ] Implement regression testing (`assert_no_regression/2`)
- [ ] Add CI/CD integration examples

#### Week 7-8: PropertyHelpers (Phase 1)
- [ ] Add StreamData dependency
- [ ] Implement basic generators:
  - [ ] `genserver_operation_sequence/2`
  - [ ] `concurrent_scenario/1`
- [ ] Implement execution helpers
- [ ] Write cookbook examples
- [ ] Integration with isolation modes

**Deliverables**:
- `PerformanceHelpers` complete with CI/CD guide
- Property testing foundation with 2 core generators
- Example-based cookbook for both modules

---

### Phase 3: Advanced Features (Weeks 9-12)

**Goals**: Distributed testing, advanced property testing, message tracing

#### Week 9-10: DistributedHelpers
- [ ] Evaluate LocalCluster vs custom implementation
- [ ] Implement cluster setup (`setup_test_cluster/1`)
- [ ] Implement partition simulation
- [ ] Implement consistency assertions
- [ ] Write multi-node test examples

#### Week 11: MessageHelpers
- [ ] Implement message tracing (`trace_messages/2`)
- [ ] Implement sequence assertions
- [ ] Implement deadlock detection
- [ ] Add debugging utilities

#### Week 12: PropertyHelpers (Phase 2)
- [ ] Implement advanced generators:
  - [ ] `supervisor_config/1`
  - [ ] `message_sequence/1` with constraints
  - [ ] `chaos_scenario/1`
- [ ] Integration with ChaosHelpers
- [ ] Shrinking optimization

**Deliverables**:
- `DistributedHelpers` complete
- `MessageHelpers` complete
- Complete `PropertyHelpers` module
- Comprehensive test suite

---

### Phase 4: Polish & Documentation (Weeks 13-14)

**Goals**: Production readiness, documentation, ecosystem integration

#### Week 13: ETSHelpers & Polish
- [ ] Implement `ETSHelpers` module
- [ ] Add telemetry integration across all modules
- [ ] Performance optimization pass
- [ ] Error handling audit
- [ ] Dialyzer compliance check

#### Week 14: Documentation & Examples
- [ ] Complete API documentation
- [ ] Write migration guide (from traditional testing)
- [ ] Write cookbook with 20+ examples
- [ ] Create video tutorials
- [ ] Prepare hex.pm release

**Deliverables**:
- All modules complete and production-ready
- Comprehensive documentation site
- Migration guide for existing projects
- v1.0.0 release to hex.pm

---

### Phase 5: Real-World Validation (Weeks 15-16)

**Goals**: Apply to target repositories, gather feedback, iterate

#### Week 15-16: Integration
- [ ] Migrate arsenal tests to Supertester
- [ ] Migrate apex tests to Supertester
- [ ] Migrate apex_ui tests to Supertester
- [ ] Migrate arsenal_plug tests to Supertester
- [ ] Migrate sandbox tests to Supertester
- [ ] Migrate cluster_test tests to Supertester
- [ ] Collect metrics (test time, failures, async coverage)
- [ ] Iterate based on real-world usage

**Success Criteria**:
- ✅ Zero test failures across all 6 repos
- ✅ All tests use `async: true`
- ✅ Zero `Process.sleep` in test code
- ✅ <30 second test execution per repo
- ✅ Property tests find at least 5 new bugs

---

## API Reference

### Quick Reference Guide

```elixir
# === Core Isolation ===
use Supertester.UnifiedTestFoundation, isolation: :full_isolation

# === OTP Setup ===
{:ok, server} = setup_isolated_genserver(MyServer, "test_context")
{:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

# === GenServer Testing ===
:ok = cast_and_sync(server, :increment)
{:ok, state} = get_server_state_safely(server)
{:ok, results} = concurrent_calls(server, [:get, :increment], 10)

# === Supervisor Testing ===
result = test_restart_strategy(supervisor, :one_for_one, {:kill_child, :worker_1})
assert_supervision_tree_structure(supervisor, expected_tree)

# === Property Testing ===
property "invariant holds" do
  check all ops <- genserver_operation_sequence([:inc, :dec], max_length: 100) do
    {:ok, server} = setup_isolated_genserver(Counter)
    test_operations(server, ops)
    assert invariant_holds(server)
  end
end

# === Chaos Testing ===
inject_crash(worker_pid, {:random, 0.3}, reason: :chaos)
report = chaos_kill_children(supervisor, kill_rate: 0.5, duration_ms: 3000)
{:ok, cleanup} = simulate_resource_exhaustion(:process_limit, percentage: 0.9)

# === Performance Testing ===
assert_performance(fn -> critical_op() end, max_time_ms: 100)
assert_no_memory_leak(10_000, fn -> handle_message() end)
benchmark_isolated("ops", %{"inc" => fn -> inc() end}, time: 5)

# === Distributed Testing ===
{:ok, cluster} = setup_test_cluster(nodes: 3)
{:ok, heal} = simulate_partition([n1, n2], [n3, n4])
assert_eventually_consistent(nodes, fn node -> get_state(node) end)

# === Message Tracing ===
{:ok, stop} = trace_messages(server)
messages = stop.()
assert_message_sequence(server, [:connect, {:data, _}, :disconnect])

# === Assertions ===
assert_process_alive(pid)
assert_genserver_state(server, fn s -> s.count > 0 end)
assert_all_children_alive(supervisor)
assert_no_process_leaks(fn -> operation() end)
```

---

## Integration Patterns

### Pattern 1: Property-Based OTP Testing

```elixir
defmodule MyApp.CounterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, PropertyHelpers, Assertions}

  property "counter invariants hold under any operation sequence" do
    check all operations <- genserver_operation_sequence(
      [:increment, :decrement, {:add, integer(-100..100)}, :reset],
      max_length: 200
    ) do
      {:ok, counter} = setup_isolated_genserver(Counter)

      final_value = Enum.reduce(operations, 0, fn op, _acc ->
        case op do
          :increment ->
            Counter.increment(counter)

          :decrement ->
            Counter.decrement(counter)

          {:add, n} ->
            Counter.add(counter, n)

          :reset ->
            Counter.reset(counter)
        end

        # Invariant: value always retrievable and >= 0
        {:ok, current} = Counter.get(counter)
        assert current >= 0
        current
      end)

      assert final_value >= 0
    end
  end

  property "concurrent operations maintain consistency" do
    check all scenario <- concurrent_scenario(
      operations: [:increment, :decrement],
      processes: 5..10,
      operations_per_process: 10..20
    ) do
      {:ok, counter} = setup_isolated_genserver(Counter)

      # Execute concurrent scenario
      tasks = for process_ops <- scenario.operations do
        Task.async(fn ->
          Enum.each(process_ops, fn op ->
            case op do
              :increment -> Counter.increment(counter)
              :decrement -> Counter.decrement(counter)
            end
          end)
        end)
      end

      Task.await_many(tasks, 5000)

      # Verify consistency
      {:ok, final_value} = Counter.get(counter)

      # Calculate expected
      total_increments = count_operations(scenario.operations, :increment)
      total_decrements = count_operations(scenario.operations, :decrement)
      expected = total_increments - total_decrements

      assert final_value == expected
    end
  end
end
```

### Pattern 2: Chaos-Driven Resilience Testing

```elixir
defmodule MyApp.SystemResilienceTest do
  use ExUnit.Case, async: false  # Chaos tests may need sequential execution
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, ChaosHelpers, Assertions}

  test "system recovers from random worker crashes" do
    {:ok, supervisor} = setup_isolated_supervisor(WorkerSupervisor)

    # Get all worker PIDs
    workers = Supervisor.which_children(supervisor)
              |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

    # Inject random crashes (30% probability)
    Enum.each(workers, fn worker ->
      inject_crash(worker, {:random, 0.3}, reason: :chaos_test)
    end)

    # Run workload
    Enum.each(1..1000, fn i ->
      WorkerSupervisor.do_work(supervisor, i)
    end)

    # Verify all workers recovered
    assert_all_children_alive(supervisor)

    # Verify no work was lost
    assert WorkerSupervisor.completed_work_count(supervisor) == 1000
  end

  test "system handles resource exhaustion gracefully" do
    {:ok, system} = start_supervised(MySystem)

    test_fn = fn ->
      # Simulate 90% process limit exhaustion
      {:ok, cleanup} = simulate_resource_exhaustion(:process_limit,
        percentage: 0.9,
        duration_ms: 5000
      )

      # Try to perform operations under pressure
      result = MySystem.create_workers(system, 100)

      # Cleanup
      cleanup.()

      # System should handle gracefully (not crash)
      assert Process.alive?(system)

      # May not complete all work, but should report gracefully
      assert match?({:ok, _} | {:error, :resource_limit}, result)
    end

    # Ensure no process leaks from the test
    assert_no_process_leaks(test_fn)
  end

  test "chaos gauntlet - comprehensive resilience" do
    {:ok, system} = setup_isolated_supervisor(MyResilientSystem)

    scenarios = [
      %{type: :crash_random_child, intensity: :medium, duration_ms: 2000},
      %{type: :message_delays, delay_range: 10..500, duration_ms: 2000},
      %{type: :resource_pressure, resource: :process_limit, percentage: 0.8}
    ]

    report = run_chaos_suite(system, scenarios, timeout: 30_000)

    # System should survive all scenarios
    assert report.passed == length(scenarios)
    assert report.failed == 0

    # System should still be functional
    assert Process.alive?(system)
    assert_all_children_alive(system)
  end
end
```

### Pattern 3: Performance Regression Testing in CI/CD

```elixir
defmodule MyApp.PerformanceTest do
  use ExUnit.Case, async: true
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, PerformanceHelpers}

  @tag :performance
  test "API performance benchmark" do
    {:ok, api_server} = setup_isolated_genserver(APIServer)

    # Run benchmark with isolation
    benchmark_isolated("api_operations", %{
      "create_user" => fn ->
        APIServer.create_user(api_server, user_params())
      end,
      "list_users" => fn ->
        APIServer.list_users(api_server)
      end,
      "update_user" => fn ->
        APIServer.update_user(api_server, 1, update_params())
      end,
      "delete_user" => fn ->
        APIServer.delete_user(api_server, 1)
      end
    },
      isolation: :full_isolation,
      time: 5,
      memory_time: 2,
      export_path: "tmp/benchmarks/current.json"
    )

    # Check for regressions against baseline
    if File.exists?("test/fixtures/api_benchmark_baseline.json") do
      assert_no_regression("api_operations",
        "test/fixtures/api_benchmark_baseline.json"
      )
    end
  end

  @tag :performance
  test "critical path performance constraints" do
    {:ok, server} = setup_isolated_genserver(CriticalServer)

    # Assert strict performance requirements
    assert_performance(
      fn -> CriticalServer.critical_operation(server, request()) end,
      max_time_ms: 50,          # Must complete in 50ms
      max_memory_bytes: 500_000, # Must use <500KB
      max_reductions: 50_000    # Limit CPU work
    )
  end

  @tag :performance
  test "message processing doesn't leak memory" do
    {:ok, processor} = setup_isolated_genserver(MessageProcessor)

    # Verify no memory leak over 100k messages
    assert_no_memory_leak(100_000, fn ->
      MessageProcessor.process(processor, random_message())
    end)
  end

  @tag :performance
  test "mailbox remains stable under load" do
    {:ok, worker} = setup_isolated_genserver(Worker)

    assert_mailbox_stable(worker,
      during: fn ->
        # Send 10k messages rapidly
        Enum.each(1..10_000, fn i ->
          GenServer.cast(worker, {:work, i})
        end)
      end,
      max_size: 100  # Mailbox should never exceed 100 messages
    )
  end
end
```

### Pattern 4: Distributed System Testing

```elixir
defmodule MyApp.DistributedTest do
  use ExUnit.Case, async: false  # Distributed tests need sequential execution
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  import Supertester.{DistributedHelpers, Assertions}

  @tag :distributed
  test "distributed cache consistency" do
    {:ok, cluster} = setup_test_cluster(nodes: 3)

    # Start cache on all nodes
    Enum.each(cluster.nodes, fn node ->
      :rpc.call(node, DistributedCache, :start_link, [])
    end)

    # Write to first node
    [node1, node2, node3] = cluster.nodes
    :rpc.call(node1, DistributedCache, :put, [:key, :value])

    # Assert eventual consistency
    assert_eventually_consistent(cluster.nodes,
      fn node ->
        :rpc.call(node, DistributedCache, :get, [:key])
      end,
      timeout_ms: 3000
    )

    # All nodes should have the value
    Enum.each(cluster.nodes, fn node ->
      assert :value == :rpc.call(node, DistributedCache, :get, [:key])
    end)

    cluster.cleanup.()
  end

  @tag :distributed
  test "system handles network partition" do
    {:ok, cluster} = setup_test_cluster(nodes: 4)
    [n1, n2, n3, n4] = cluster.nodes

    # Start distributed system on all nodes
    Enum.each(cluster.nodes, fn node ->
      :rpc.call(node, MyDistSystem, :start_link, [])
    end)

    # Create network partition
    {:ok, heal} = simulate_partition([n1, n2], [n3, n4], duration_ms: 5000)

    # Verify split-brain handling
    # Each partition should continue operating
    assert :ok == :rpc.call(n1, MyDistSystem, :operation, [])
    assert :ok == :rpc.call(n3, MyDistSystem, :operation, [])

    # Heal partition
    heal.()

    # Verify reconciliation
    assert_eventually_consistent(cluster.nodes,
      fn node ->
        :rpc.call(node, MyDistSystem, :get_state, [])
      end,
      timeout_ms: 10_000
    )

    cluster.cleanup.()
  end
end
```

---

## Performance Considerations

### Memory Usage

**Isolation Overhead**:
- `:basic` - Minimal (~100 bytes per test)
- `:registry` - Low (~1KB per test)
- `:full_isolation` - Moderate (~10KB per test)
- `:contamination_detection` - Higher (~50KB per test)

**Optimization Strategies**:
1. Use appropriate isolation level for test requirements
2. Batch property tests to reuse isolation context
3. Limit concurrent test processes (ExUnit `max_cases`)
4. Use `@tag :tmp_dir` for file isolation instead of custom logic

### Test Execution Time

**Target Metrics**:
- Example tests: <1ms per test
- Property tests: <100ms per property (100 iterations)
- Chaos tests: <5s per scenario
- Performance tests: Depends on benchmark time

**Optimization Techniques**:
1. Eliminate all `Process.sleep` - use monitors/refs
2. Parallel test execution (`async: true`)
3. Lazy resource allocation
4. Efficient process cleanup (avoid timeouts)

### Scalability

**Targets**:
- Support 10,000+ tests per repository
- Support 100+ concurrent test processes
- Handle repositories with 100+ GenServers

**Strategies**:
1. Process pooling for common test fixtures
2. Lazy loading of optional dependencies
3. Incremental test selection (only changed modules)
4. Distributed test execution (future)

---

## Testing Strategy

### Testing the Test Library

**Challenges**:
- Testing code that tests code (meta-testing)
- Race conditions in concurrency tests
- Flaky test detection
- Performance test reliability

**Approach**:

#### Unit Tests
- Test each helper function in isolation
- Mock external dependencies (`:sys`, `:erlang`, etc.)
- Verify error handling paths

#### Integration Tests
- Test with real GenServers and Supervisors
- Verify isolation actually works
- Test cleanup behavior

#### Property Tests
- Test generators produce valid output
- Test shrinking produces minimal examples
- Test chaos scenarios don't crash test framework

#### Meta-Tests
- Run tests with intentional failures to verify detection
- Verify memory leak detection catches actual leaks
- Verify chaos helpers actually inject faults

#### Performance Tests
- Benchmark isolation overhead
- Benchmark helper function performance
- Detect regressions in test framework itself

### Continuous Integration

**CI Pipeline**:
```yaml
# .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        elixir: [1.14, 1.15, 1.16, 1.17, 1.18]
        otp: [24, 25, 26, 27]

    steps:
      - uses: actions/checkout@v2

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ matrix.elixir }}
          otp-version: ${{ matrix.otp }}

      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
      - run: mix test --only property
      - run: mix test --only chaos
      - run: mix test --only performance
      - run: mix test --only distributed

      - run: mix dialyzer
      - run: mix credo --strict
      - run: mix format --check-formatted
```

---

## Migration Guide

### Migrating from Traditional ExUnit Testing

#### Before (Traditional Pattern)
```elixir
defmodule MyApp.OldCounterTest do
  use ExUnit.Case, async: false  # Can't use async due to global state

  setup do
    # Manual process start with global name
    {:ok, _pid} = GenServer.start_link(Counter, [], name: Counter)

    # Manual cleanup - often forgotten!
    on_exit(fn ->
      if Process.whereis(Counter) do
        GenServer.stop(Counter)
      end
    end)

    :ok
  end

  test "incrementing the counter" do
    # Operation
    GenServer.cast(Counter, :increment)

    # Hope 50ms is enough! (FRAGILE)
    Process.sleep(50)

    # Verify
    state = :sys.get_state(Counter)
    assert state.count == 1
  end

  test "concurrent access" do
    # Manual concurrent testing (VERBOSE)
    tasks = for i <- 1..10 do
      Task.async(fn ->
        GenServer.cast(Counter, :increment)
        Process.sleep(10)  # More hoping!
      end)
    end

    Task.await_many(tasks)
    Process.sleep(100)  # Extra sleep just to be safe...

    state = :sys.get_state(Counter)
    assert state.count == 10
  end
end
```

#### After (Supertester Pattern)
```elixir
defmodule MyApp.NewCounterTest do
  use ExUnit.Case, async: true  # ✅ Can use async!
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  # No setup needed - isolation handles it!

  test "incrementing the counter" do
    # Isolated setup (unique name, automatic cleanup)
    {:ok, counter} = setup_isolated_genserver(Counter)

    # Deterministic synchronization (no sleep!)
    :ok = cast_and_sync(counter, :increment)

    # Expressive assertion
    assert_genserver_state(counter, fn state -> state.count == 1 end)
  end

  test "concurrent access" do
    {:ok, counter} = setup_isolated_genserver(Counter)

    # Built-in concurrent testing
    {:ok, results} = concurrent_calls(counter, [:increment], 10)

    # All calls should succeed
    assert length(results) == 1
    assert {:increment, successes} = hd(results)
    assert length(successes) == 10

    assert_genserver_state(counter, fn state -> state.count == 10 end)
  end

  # BONUS: Property-based testing (impossible before!)
  property "any operation sequence maintains invariants" do
    check all operations <- genserver_operation_sequence(
      [:increment, :decrement, :reset],
      max_length: 100
    ) do
      {:ok, counter} = setup_isolated_genserver(Counter)

      Enum.each(operations, fn op ->
        case op do
          :increment -> cast_and_sync(counter, :increment)
          :decrement -> cast_and_sync(counter, :decrement)
          :reset -> cast_and_sync(counter, :reset)
        end
      end)

      # Invariant: count always >= 0
      assert_genserver_state(counter, fn state -> state.count >= 0 end)
    end
  end
end
```

### Migration Checklist

- [ ] Replace `Process.sleep` with `cast_and_sync` or `wait_for_genserver_sync`
- [ ] Add `use Supertester.UnifiedTestFoundation` with appropriate isolation
- [ ] Replace manual `GenServer.start_link` with `setup_isolated_genserver`
- [ ] Remove manual cleanup code (handled by isolation)
- [ ] Change `async: false` to `async: true` where possible
- [ ] Replace manual concurrent testing with `concurrent_calls` or `concurrent_scenario`
- [ ] Add property tests for complex logic
- [ ] Add chaos tests for critical systems
- [ ] Add performance tests for critical paths

### Estimated Migration Effort

**Small Project** (< 100 tests):
- 2-4 hours for basic migration
- 1-2 days for full enhancement (properties, chaos, performance)

**Medium Project** (100-500 tests):
- 1-2 days for basic migration
- 1 week for full enhancement

**Large Project** (500+ tests):
- 3-5 days for basic migration
- 2-3 weeks for full enhancement

**Benefits**:
- ✅ Tests run faster (parallel + no sleep)
- ✅ Tests more reliable (no race conditions)
- ✅ Better coverage (property tests find edge cases)
- ✅ Better resilience (chaos tests validate assumptions)

---

## Appendix

### Telemetry Events Reference

```elixir
# Isolation events
[:supertester, :isolation, :setup]
# Metadata: %{isolation_type: atom, test_id: atom}

[:supertester, :isolation, :cleanup]
# Metadata: %{isolation_type: atom, processes_cleaned: integer, duration_ms: integer}

# Chaos events
[:supertester, :chaos, :crash_injected]
# Metadata: %{target: pid, reason: term, crash_spec: term}

[:supertester, :chaos, :child_killed]
# Metadata: %{supervisor: pid, child_id: term, child_pid: pid, restarted: boolean}

[:supertester, :chaos, :resource_exhaustion]
# Metadata: %{resource: atom, consumed: integer, limit: integer}

# Performance events
[:supertester, :performance, :benchmark_start]
# Metadata: %{name: String.t, isolation: atom}

[:supertester, :performance, :benchmark_complete]
# Metadata: %{name: String.t, duration_ms: integer, scenarios: integer}

[:supertester, :performance, :regression_detected]
# Metadata: %{benchmark: String.t, current_ms: float, baseline_ms: float, regression_pct: float}

# Property testing events
[:supertester, :property, :test_start]
# Metadata: %{property_name: String.t, iterations: integer}

[:supertester, :property, :failure]
# Metadata: %{property_name: String.t, iteration: integer, shrunk_input: term}

# Distributed events
[:supertester, :distributed, :cluster_start]
# Metadata: %{nodes: [node()], node_count: integer}

[:supertester, :distributed, :partition_created]
# Metadata: %{group_a: [node()], group_b: [node()]}

[:supertester, :distributed, :partition_healed]
# Metadata: %{nodes: [node()], duration_ms: integer}
```

### Glossary

**Chaos Engineering**: Discipline of experimenting on a system to build confidence in capability to withstand turbulent conditions

**Property-Based Testing**: Testing approach that verifies properties/invariants hold for generated inputs rather than specific examples

**Shrinking**: Process of reducing failing input to minimal example that still triggers failure

**Test Isolation**: Preventing test state/side effects from affecting other tests

**OTP**: Open Telecom Platform - Erlang/Elixir framework for building fault-tolerant systems

**GenServer**: Generic server behavior in OTP

**Supervision Tree**: Hierarchical structure of supervisors managing worker processes

**Process Registry**: System for registering processes by name

**ETS**: Erlang Term Storage - in-memory database

---

**Document Version**: 1.0
**Last Updated**: October 7, 2025
**Authors**: Supertester Core Team
**Status**: DRAFT - Ready for Implementation

---

## Next Steps

1. **Review & Feedback**: Circulate to team for technical review
2. **Prioritization**: Finalize implementation order based on business needs
3. **Spike**: Conduct 1-week spike on PropertyHelpers + StreamData integration
4. **Kickoff**: Begin Phase 1 implementation

**Questions? Feedback?**
Open an issue on GitHub or contact the team.
