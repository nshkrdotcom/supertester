# Supertester API Guide

Version: 0.6.0  
Last Updated: March 3, 2026

This guide documents the main public APIs and behavior-sensitive edge cases.

## Core

### `Supertester.version/0`

```elixir
@spec version() :: String.t()
```

### `Supertester.ExUnitFoundation`

```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

Options:

- `:isolation` - `:basic | :registry | :full_isolation | :contamination_detection`
- `:telemetry_isolation`
- `:logger_isolation`
- `:ets_isolation`

## OTP Helpers

### `Supertester.OTPHelpers`

```elixir
@spec setup_isolated_genserver(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
@spec setup_isolated_supervisor(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
@spec wait_for_genserver_sync(GenServer.server(), timeout()) :: :ok | {:error, term()}
@spec wait_for_process_restart(atom(), pid(), timeout()) :: {:ok, pid()} | {:error, term()}
@spec wait_for_supervisor_restart(Supervisor.supervisor(), timeout()) :: {:ok, pid()} | {:error, term()}
@spec monitor_process_lifecycle(pid()) :: {reference(), pid()}
@spec wait_for_process_death(pid(), timeout()) :: {:ok, term()} | {:error, :timeout}
@spec cleanup_processes([pid()]) :: :ok
@spec cleanup_on_exit((-> any())) :: :ok
```

### `Supertester.GenServerHelpers`

```elixir
@spec get_server_state_safely(GenServer.server()) :: {:ok, term()} | {:error, term()}
@spec call_with_timeout(GenServer.server(), term(), timeout()) :: {:ok, term()} | {:error, term()}
@spec cast_and_sync(GenServer.server(), term(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
@spec concurrent_calls(GenServer.server(), [term()], pos_integer(), keyword()) :: {:ok, [map()]}
@spec stress_test_server(GenServer.server(), [term()], pos_integer(), keyword()) :: {:ok, map()}
@spec test_server_crash_recovery(GenServer.server(), term()) :: {:ok, map()} | {:error, term()}
@spec test_invalid_messages(GenServer.server(), [term()]) :: {:ok, [{term(), term()}]}
```

`cast_and_sync/4` semantics:

- missing sync support:
  - `strict?: true` raises `ArgumentError`.
  - `strict?: false` returns `{:error, :missing_sync_handler}`.
- handled sync replies return `{:ok, reply}`.
- covers missing-handler crashes raised as both runtime and function-clause exit shapes.

### `Supertester.TestableGenServer`

Injects:

- `handle_call(:__supertester_sync__, ...)`
- `handle_call({:__supertester_sync__, opts}, ...)`

## Supervisor Helpers

### `Supertester.SupervisorHelpers`

```elixir
@spec test_restart_strategy(Supervisor.supervisor(), atom(), restart_scenario()) :: test_result()
@spec trace_supervision_events(Supervisor.supervisor(), keyword()) :: {:ok, (-> [supervision_event()])}
@spec assert_supervision_tree_structure(Supervisor.supervisor(), tree_structure()) :: :ok
@spec wait_for_supervisor_stabilization(Supervisor.supervisor(), timeout()) :: :ok | {:error, :timeout}
@spec get_active_child_count(Supervisor.supervisor()) :: non_neg_integer()
```

Behavior notes:

- `test_restart_strategy/3` raises on strategy mismatch and unknown scenario child IDs.
- removed temporary children are not classified as restarted.

## Chaos

### `Supertester.ChaosHelpers`

```elixir
@spec inject_crash(pid(), crash_spec(), keyword()) :: :ok
@spec chaos_kill_children(Supervisor.supervisor(), keyword()) :: chaos_report()
@spec simulate_resource_exhaustion(atom(), keyword()) :: {:ok, (-> :ok)} | {:error, term()}
@spec assert_chaos_resilient(pid(), (-> any()), (-> boolean()), keyword()) :: :ok
@spec run_chaos_suite(pid(), [map()], keyword()) :: chaos_suite_report()
```

Behavior notes:

- `chaos_kill_children/2` accepts pid and registered supervisor names for supervisor-based scenarios.
- `restarted` counts observed child replacements, including cascade replacements.
- `run_chaos_suite/3`:
  - applies suite deadline with `:timeout` and `:suite_timeout` when execution overruns.
  - does not treat ordinary scenario failures with reason `:timeout` as suite timeout cutoffs.

## Assertions

### `Supertester.Assertions`

```elixir
@spec assert_process_alive(pid()) :: :ok
@spec assert_process_dead(pid()) :: :ok
@spec assert_process_restarted(atom(), pid()) :: :ok
@spec assert_genserver_state(GenServer.server(), term() | (term() -> boolean())) :: :ok
@spec assert_genserver_responsive(GenServer.server()) :: :ok
@spec assert_genserver_handles_message(GenServer.server(), term(), term()) :: :ok
@spec assert_supervisor_strategy(Supervisor.supervisor(), atom()) :: :ok
@spec assert_child_count(Supervisor.supervisor(), non_neg_integer()) :: :ok
@spec assert_all_children_alive(Supervisor.supervisor()) :: :ok
@spec assert_memory_usage_stable((-> any()), float()) :: :ok
@spec assert_no_process_leaks((-> any())) :: :ok
@spec assert_performance_within_bounds(map(), map()) :: :ok
```

`assert_no_process_leaks/1`:

- traces spawned/linked descendants attributable to the operation.
- catches delayed descendant leaks.
- ignores short-lived transient processes.

## Performance

### `Supertester.PerformanceHelpers`

```elixir
@spec assert_performance((-> any()), keyword()) :: :ok
@spec assert_expectations(map(), keyword()) :: :ok
@spec assert_no_memory_leak(pos_integer(), (-> any()), keyword()) :: :ok
@spec measure_operation((-> any())) :: map()
@spec measure_mailbox_growth(pid(), (-> any()), keyword()) :: map()
@spec assert_mailbox_stable(pid(), keyword()) :: :ok
@spec compare_performance(map()) :: map()
```

## Concurrency and Diagnostics

### `Supertester.ConcurrentHarness`

```elixir
@spec run(scenario()) :: {:ok, map()} | {:error, term()}
@spec run_with_performance(scenario(), keyword()) :: {:ok, map()} | {:error, term()}
@spec simple_genserver_scenario(module(), [term() | operation()], pos_integer(), keyword()) :: Scenario.t()
@spec from_property_config(module(), map(), keyword()) :: Scenario.t()
@spec chaos_kill_children(keyword()) :: chaos_fun()
@spec chaos_inject_crash(ChaosHelpers.crash_spec(), keyword()) :: chaos_fun()
```

### `Supertester.PropertyHelpers`

StreamData-based operation/scenario generators.

### `Supertester.MessageHarness`

```elixir
@spec trace_messages(pid(), (-> any()), keyword()) :: %{
  messages: [term()],
  result: term(),
  initial_mailbox: [term()],
  final_mailbox: [term()]
}
```

### `Supertester.Telemetry` and `Supertester.TelemetryHelpers`

Telemetry namespace and per-test telemetry isolation helpers.

### `Supertester.LoggerIsolation` and `Supertester.ETSIsolation`

Per-test logger/ETS isolation helpers.
