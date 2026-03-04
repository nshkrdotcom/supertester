# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-03-02

### Added
- `TelemetryHelpers.detach_isolated/1` for explicit teardown of isolated telemetry handlers and associated buffers.
- `TelemetryHelpers.flush_buffered_telemetry/1` for draining buffered telemetry events by handler ID.
- Internal module `Supertester.Internal.Poller` — unified deadline-based polling utility replacing hand-rolled `wait_for_*_loop` patterns across the codebase.
- Internal module `Supertester.Internal.ProcessLifecycle` — consolidated process stop/cleanup logic with `:shutdown` escalation to `:kill` and unlinking before stop.
- Internal module `Supertester.Internal.ProcessRef` — unified name resolution for pid, atom, `{:global, _}`, and `{:via, _, _}` references.
- Internal module `Supertester.Internal.SharedRegistry` — single shared `Registry` (`:supertester_shared_registry`) for all test process name registration, replacing per-test registries.
- Internal module `Supertester.Internal.SupervisorIntrospection` — shared supervisor introspection utilities (`extract_supervisor_strategy`, `extract_supervisor_module`, `resolve_supervisor_pid`, `group_child_pids_by_id`) extracted from `Assertions`, `SupervisorHelpers`, and `ChaosHelpers`.
- Internal module `Supertester.Internal.IsolationContextStore` — consolidated `maybe_update_context/1` pattern shared by `ETSIsolation`, `LoggerIsolation`, and `TelemetryHelpers`.
- Internal module `Supertester.Internal.TelemetryBuffer` — anonymous Agent-based telemetry event buffer replacing per-process dynamically-named agents.
- Internal module `Supertester.Internal.TelemetryHandlerBuffers` — process dictionary manager mapping handler IDs to buffer pids.
- Internal module `Supertester.Internal.TelemetryMailbox` — extracted telemetry mailbox receive/flush/collect logic from `TelemetryHelpers`.
- Internal module `Supertester.Internal.Chaos.ResourceExhaustion` — extracted resource exhaustion simulation logic from `ChaosHelpers`.
- Internal module `Supertester.Internal.Chaos.SuiteRunner` — timeout-aware chaos suite execution with per-scenario deadline enforcement.
- Internal module `Supertester.ConcurrentHarness.Runtime` — execution engine extracted from `ConcurrentHarness` (~420 lines).
- Comprehensive test suites for `Assertions`, `ChaosHelpers` edge cases, `ConcurrentHarness` API contract stability, `ETSIsolation` cleanup behavior, and all new internal modules (`Poller`, `ProcessLifecycle`, `ProcessRef`, `SharedRegistry`, `SupervisorIntrospection`, `TelemetryBuffer`).
- Atom safety regression tests verifying zero unbounded atom creation during isolation setup, ETS exhaustion simulation, and concurrent telemetry usage.
- Regression tests for `cast_and_sync/4` function-clause missing-sync handling, temporary-child restart reporting, `:one_for_all` cascade restart accounting, ordinary `:timeout` scenario failure handling in `run_chaos_suite/3`, and short-lived transient process handling in `assert_no_process_leaks/1`.
- `Supertester.Internal.IsolationContextStore.put_updated/2` to consolidate context mutation + persistence in one internal helper.
- `Supertester.Internal.SupervisorIntrospection.safe_children/1`, `replacement_count/2`, and `child_restarted?/2` for shared supervisor-state/restart analysis across helpers.
- Targeted regression tests for shared registry stale-name/reset recovery, memory trend analysis behavior, message trace timeout handling, and isolation context store update semantics.
- Internal module `Supertester.Internal.ProcessWatch` — shared monitor/`DOWN` wait utility used across lifecycle-sensitive internals.
- Focused internal test coverage for `TelemetryMailbox` selective flush/requeue behavior and `ProcessWatch` timeout/down semantics.
- Cleanup regression coverage for mailbox monitor tasks on `raise`/`throw`/`exit`, concurrent-harness timeout cleanup, and shared-registry lifecycle stability under repeated isolation setup.

### Changed
- **`GenServerHelpers.cast_and_sync/4`**: Non-strict mode now consistently returns `{:error, :missing_sync_handler}` instead of `:ok` when sync handling is missing. Any successful sync call reply (including `{:error, :unknown_call}`) is treated as synchronized and returns `{:ok, reply}`.
- **`SupervisorHelpers.test_restart_strategy/3`**: Raises `ArgumentError` when scenario child IDs are missing or when the supervisor's actual strategy does not match the expected strategy.
- **`SupervisorHelpers.assert_supervision_tree_structure/2`**: Now validates expected child modules for leaf children and optional `:supervisor`/`:strategy` keys in the expected structure.
- **`SupervisorHelpers.wait_for_supervisor_stabilization/2`**: Now delegates directly to `UnifiedTestFoundation.wait_for_supervision_tree_ready/2` (flattened wrapper chain).
- **`Assertions.assert_supervisor_strategy/2`**: Now validates runtime supervisor strategy via `:sys.get_state/1` introspection instead of only verifying process accessibility. Handles both tuple-based (standard Supervisor) and map-based (DynamicSupervisor) internal state formats.
- **`Assertions.assert_no_process_leaks/1`**: Uses `:erlang.trace/3` to scope leak detection to processes spawned/linked by the operation caller, with a post-operation grace window for delayed descendant detection. Replaces global `Process.list()` snapshot comparison.
- **`ChaosHelpers.chaos_kill_children/2`**: Treats `kill_rate <= 0` as a no-kill run. Restart accounting now includes observed cascade replacements (e.g., `:one_for_all` sibling restarts).
- **`ChaosHelpers.run_chaos_suite/3`**: Accepts `timeout:` option for suite-wide deadline enforcement. Distinguishes true deadline overruns from ordinary scenario failures with reason `:timeout`.
- **`ChaosHelpers.simulate_resource_exhaustion/2`**: Non-positive `spawn_count`/`count` values treated as no-op instead of allocating resources via descending ranges. ETS table names use a single reusable atom instead of per-table dynamic atoms.
- **`ETSIsolation.inject_table/3-4`**: Fallback path rejects dynamic atom creation; requires a pre-existing env key or `__supertester_set_table__/2` callback. Restore is now idempotent via injection tracking.
- **`OTPHelpers.safe_start/4`**: Uses a spawned intermediary process for `start_link` calls instead of setting `trap_exit` on the test process, preventing side effects on ExUnit's process monitoring.
- **`OTPHelpers` process naming**: Switched from dynamic atom creation (`String.to_atom/1`) to `{:via, Registry, {:supertester_shared_registry, ...}}` tuples for zero-atom-allocation naming. Single shared Registry replaces per-test registries.
- **`UnifiedTestFoundation.generate_test_id/1`**: Returns a string instead of an atom.
- **`IsolationContext.t()`**: `:name` and `:registry` fields broadened from `atom() | nil` to `term() | nil` to support `{:via, ...}` tuples.
- **`ExUnitFoundation.__using__/1`**: Setup logic extracted to named functions (`maybe_setup_telemetry/2`, `maybe_setup_logger/3`, `maybe_setup_ets/2`) instead of being inlined in the macro.
- **`TelemetryHelpers`**: Buffer Agent now uses `Agent.start_link` (linked) with anonymous process naming instead of `Agent.start` (unlinked) with `:global` dynamic atom names, preventing resource leaks on test crashes.
- **`ConcurrentHarness`**: Execution engine (~420 lines) extracted to `ConcurrentHarness.Runtime`, leaving the public module as a thin delegation layer.
- `ex_doc` dependency bumped from `~> 0.27` to `~> 0.40`.
- `Supertester` moduledoc updated from "Multi-repository test orchestration" to "OTP-focused testing toolkit".
- **`PerformanceHelpers.assert_no_memory_leak/3`**: Reworked to use warmup + evenly distributed sampling + robust trend analysis instead of a fragile first/last sample delta. Added optional tuning keys (`:sample_count`, `:warmup_iterations`, `:min_absolute_growth_bytes`, `:min_upward_ratio`).
- **`SupervisorHelpers` / `ChaosHelpers` / `ProcessLifecycle`**: Consolidated supervisor child safety and restart-diff logic to shared `SupervisorIntrospection` internals.
- **`ETSIsolation` context setup paths**: Reduced duplicated context wiring by using shared `IsolationContextStore.put_updated/2`.
- **`ETSIsolation` injection cleanup**: Removed legacy cleanup entry-shape handling; cleanup now processes canonical `{injection_id, injection, delete_on_cleanup?}` entries only.
- **`TelemetryHelpers.with_telemetry/3`**: Removed redundant buffer flush after handler detach.
- **`SharedRegistry.ensure_started/0`**: Simplified to a global-lock guarded start-or-reuse path with targeted stale recovery; avoids multi-branch retry loops while keeping reset recovery behavior.
- **`ChaosHelpers.inject_crash/3` (`{:after_ms, _}`)**: Delayed injectors now monitor the target and cancel immediately on target exit, enforcing guaranteed cancellation semantics.
- **`PerformanceHelpers.measure_mailbox_growth/3`**: Mailbox monitor tasks are now always stopped/joined, including exception (`raise`/`throw`/`exit`) paths.
- **`TelemetryMailbox` + `TelemetryHelpers` selective flush paths**: Consolidated flush filtering internals and switched selective flush behavior to preserve non-matching telemetry messages.
- **`ETSIsolation.setup_ets_isolation/*`**: Setup overloads now share one initialization pipeline and explicit context fetch path (removed no-op context update pattern).

### Fixed
- **`ChaosHelpers.chaos_kill_children/2`**: No longer exits the caller when the supervisor dies mid-loop; returns a report with `supervisor_crashed: true`. Now accepts registered supervisor names (atom, `{:global, _}`, `{:via, _, _}`). Handles duplicate child IDs correctly (e.g., dynamic children with `:undefined` IDs).
- **`GenServerHelpers.cast_and_sync/4`**: Recognizes missing sync handlers when the server crashes with a `FunctionClauseError` exit shape. Returns `{:error, :missing_sync_handler}` in non-strict mode when sync probing reveals a missing handler via process exit. Documentation now correctly distinguishes bare `:ok` return from `{:ok, reply}` return.
- **`SupervisorHelpers.test_restart_strategy/3`**: No longer misclassifies removed temporary children as restarted. Enforces expected strategy/module checks including map-based supervisor internals (`DynamicSupervisor`).
- **`Assertions.assert_no_process_leaks/1`**: Corrected `:spawned` trace handling; improved persistence checks to reduce false positives from unrelated/self trace events while preserving delayed-descendant leak detection.
- **`TelemetryHelpers`** buffered event capture no longer creates per-process dynamic atoms for buffer naming. Buffer Agent no longer leaks when test process crashes (now linked to caller).
- Isolation and helper naming paths no longer rely on unbounded dynamic atom creation (`test_id` is string-based; shared registry/process naming are atom-safe).
- `ProcessLifecycle.stop_process_safely/2` uses `:shutdown` instead of `:normal` exit reason and unlinks before stopping to prevent exit propagation to the test process.
- `ProcessRef.resolve/1` normalizes `:undefined` from `:global.whereis_name` and `module.whereis_name` to `nil` instead of leaking the `:undefined` atom.
- `UnifiedTestFoundation.supervisor_ready_probe/1` now rescues/catches exits instead of crashing the poller.
- ETS injection restore is now idempotent — duplicate restore calls are tracked and skipped via injection IDs.
- Shared registry is unlinked from creator to survive when spawned from short-lived Task processes.
- Refactored `GenServerHelpers.concurrent_calls/4` internals to satisfy strict Credo nesting limits.
- Intermittent full-suite failures caused by shared registry startup races and stale `PIDPartition` processes after reset/teardown.
- Intermittent false negatives in `assert_no_memory_leak/3` under suite load by requiring sustained upward trend + meaningful absolute growth before flagging leaks.
- `MessageHarness.trace_messages/3` timeout path now raises a descriptive `RuntimeError` and shuts down the collector task deterministically.
- `TelemetryHelpers.flush_telemetry/1` no longer drops unrelated telemetry messages when flushing a specific event pattern.
- Delayed crash injectors no longer linger for full timeout after target termination.
- `measure_mailbox_growth/3` no longer leaks monitor tasks when wrapped operations fail via exceptions or exits.
- CI flakiness in chaos/performance tests reduced by replacing global VM count/timing-order assertions with deterministic resource lifecycle assertions (captured pids/table IDs and teardown verification).

### Documentation
- README and guides refreshed for 0.6.0 API behavior (strict sync guidance, supervisor validation semantics, chaos suite timeout behavior, expanded helper coverage).
- `cast_and_sync/4` return value semantics corrected across README, QUICK_START, MANUAL, and API_GUIDE.
- Restored onboarding content: prerequisites (TestableGenServer), common patterns, and troubleshooting sections added to QUICK_START and MANUAL.
- `Supertester.Env` documented in API_GUIDE and MANUAL with behaviour spec and custom implementation example.
- Added `skip_code_autolink_to` for `Supertester.Env.ExUnit` and `Supertester.Internal.SupervisorIntrospection` to fix docs build warnings.
- Added migration guide for upgrading from 0.5.1 to 0.6.0.

### Migration from 0.5.1

If upgrading from 0.5.x to 0.6.0, note the following breaking changes:

1. **`cast_and_sync/4` missing-sync behavior**: Non-strict mode now consistently returns `{:error, :missing_sync_handler}` instead of `:ok` for servers without sync handlers. Update assertions that matched bare `:ok` for servers without sync support.

2. **`test_restart_strategy/3` raises on missing children and strategy mismatch**: Scenario child IDs that do not exist in the supervisor now raise `ArgumentError`. The supervisor's actual strategy must also match the expected strategy. Ensure all scenario child IDs match actual supervisor children.

3. **`assert_supervision_tree_structure/2` validates child modules**: Leaf children now have their modules checked. Tests that only validated child IDs may need updating.

4. **`ETSIsolation.inject_table/3-4` atom safety**: Fallback path no longer creates dynamic atoms. Use `__supertester_set_table__/2` callback or pre-existing env keys.

5. **Process naming format**: Process names generated by `setup_isolated_genserver/3` and `setup_isolated_supervisor/3` use `{:via, Registry, {:supertester_shared_registry, ...}}` instead of `{:global, ...}` tuples. Code that pattern-matches on the exact name structure must be updated.

6. **`generate_test_id/1` returns a string**: Test IDs are now strings, not atoms. Code using `is_atom(test_id)` or `Atom.to_string(test_id)` must be updated to use `to_string/1` or match on strings.

7. **`safe_start/4` no longer sets `trap_exit` on the test process**: The function now uses a spawned intermediary. Tests relying on the side effect of `trap_exit` being set must trap exits explicitly.

8. **`wait_for_supervisor_stabilization/2` delegation changed**: Now delegates to `OTPHelpers.wait_for_supervisor_restart/2` rather than `UnifiedTestFoundation.wait_for_supervision_tree_ready/2`.

## [0.5.1] - 2026-01-09

### Fixed
- `Supertester.TestableGenServer` no longer emits a private `@doc` warning when used without `GenServer`.

## [0.5.0] - 2026-01-06

### Added
- EchoLab example app demonstrating full Supertester coverage under `examples/`.

### Changed
- Documentation reorganized under `guides/` and refreshed for 0.5.0 coverage.

### Fixed
- `setup_isolated_supervisor/3` now passes init args correctly when starting supervisors.
- GenServer helper name resolution now supports `{:global, _}` and `{:via, _, _}` registrations.
- Mailbox monitoring handles process exits during sampling and avoids redundant messaging.
- Telemetry buffering avoids Agent startup races under concurrency.
- GenServer state assertions now support scalar expected values.
- Supervisor strategy assertion documentation clarified to reflect public API limits.

### Removed
- `get_supervisor_strategy/1` (unfinished API) has been dropped.
- Legacy release summary documentation has been removed.

## [0.4.0] - 2025-12-26

### Added
- **Supertester.TelemetryHelpers** for async-safe telemetry assertions with test-scoped handlers, buffering, and helper macros.
- **Supertester.LoggerIsolation** for per-process Logger level isolation and safe log capture helpers.
- **Supertester.ETSIsolation** for isolated ETS table creation, mirroring, and table injection with automatic cleanup.
- ExUnitFoundation options `telemetry_isolation`, `logger_isolation`, and `ets_isolation`, plus tag-based telemetry, logger, and ETS configuration.
- New telemetry events covering isolation setup, handler lifecycle, and ETS table operations.

### Changed
- **Supertester.IsolationContext** extended with telemetry, logger, and ETS isolation state fields.

## [0.3.1] - 2025-11-19

### Added
- **Supertester.ConcurrentHarness** providing a scenario-based runner with thread scripts, invariants, structured event reporting, and optional mailbox metrics.
- **Supertester.PropertyHelpers** exposing `genserver_operation_sequence/2` and `concurrent_scenario/1` generators that emit configs consumed by the concurrent harness or property-based tests.
- **Supertester.MessageHarness** with `trace_messages/3` for lightweight mailbox visibility during any operation.
- Regression tests covering the new harness layer, message tracing utility, and property generators (when `:stream_data` is available).
- **Supertester.Telemetry** centralized module plus global `:telemetry` dependency, enabling harness lifecycle, chaos, mailbox, and performance events out of the box.
- ConcurrentHarness chaos helpers (`chaos_kill_children/1`, `chaos_inject_crash/2`) and `run_with_performance/2` helper for composing richer scenarios.
- `ChaosHelpers.run_chaos_suite/3` can now consume full `Supertester.ConcurrentHarness` scenarios (via `:concurrent` entries), consolidating telemetry and reporting across chaos suites.

### Changed
- `PerformanceHelpers.measure_mailbox_growth/3` now accepts options (sampling interval) and returns the wrapped operation result so higher-level APIs can forward diagnostics.
- `assert_mailbox_stable/2` forwards extra options to the new mailbox measurement signature, enabling finer-grained monitoring from tests and the concurrent harness.
- ConcurrentHarness integrates optional chaos hooks, performance expectations, and emits telemetry events for scenario start/stop and diagnostics.

### Fixed
- Documentation now reflects the new concurrent harness and mailbox utilities, replacing stale references to planned modules that did not yet exist.

## [0.3.0] - 2025-11-19

### Added
- **Supertester.ExUnitFoundation** — drop-in ExUnit adapter that automatically wires `Supertester.UnifiedTestFoundation` isolation and sets async mode based on the selected strategy.
- **Supertester.Env** and configurable environment behaviour, enabling custom harnesses to override how on-exit cleanup callbacks are registered.
- **Supertester.IsolationContext** struct for consistent tracking of processes, ETS tables, cleanup callbacks, and contextual tags.
- Dedicated tests covering the new Env abstraction, ExUnit adapter behaviour, and enhanced helpers.

### Changed
- `Supertester.UnifiedTestFoundation` now focuses purely on managing isolation contexts, exposes helpers to fetch/update those contexts, and registers cleanup via the new environment abstraction. The legacy macro now warns and delegates to the ExUnit adapter.
- `Supertester.OTPHelpers` improved process tracking, derives deterministic names from the isolation context, traps exits to prevent linked process crashes from taking down tests, and returns richer error metadata when isolated processes fail to start.
- `Supertester.GenServerHelpers` gained stricter `cast_and_sync/4`, structured `concurrent_calls/4` output, configurable timeouts, parallel stress-test workers, and better logging around missing sync handlers.
- Documentation (README, MANUAL, API guide, technical design doc, etc.) updated to reflect the new ExUnit adapter, environment abstraction, and enhanced helper APIs.

### Fixed
- Stress tests now aggregate worker metrics reliably and include execution duration, avoiding missed worker exits.
- `cast_and_sync/4` handles servers that raise when sync handlers are missing, providing clearer errors when `strict?: true` is enabled.

## [0.2.1] - 2025-10-17

### Fixed
- Fixed missing logo asset in hex.pm package (404 error on hexdocs)
  - Added `assets` directory to package files list in mix.exs
  - Logo now correctly displays in HexDocs at https://hexdocs.pm/supertester

## [0.2.0] - 2025-10-07

### Added
- **Supertester.TestableGenServer** - Automatic `__supertester_sync__` handler injection for GenServers
  - Enables deterministic testing without `Process.sleep/1`
  - Works with `use Supertester.TestableGenServer` in any GenServer
  - Supports state return option for debugging
- **Supertester.SupervisorHelpers** - Comprehensive supervision tree testing toolkit
  - `test_restart_strategy/3` - Test one_for_one, one_for_all, rest_for_one strategies
  - `assert_supervision_tree_structure/2` - Validate tree structure
  - `trace_supervision_events/2` - Monitor supervisor events
  - `wait_for_supervisor_stabilization/2` - Wait for all children ready
  - `get_active_child_count/1` - Get active child count
- **Supertester.ChaosHelpers** - Chaos engineering for OTP resilience testing
  - `inject_crash/3` - Controlled crash injection (immediate, delayed, random)
  - `chaos_kill_children/2` - Random child killing in supervision trees
  - `simulate_resource_exhaustion/2` - Process/ETS/memory limit simulation
  - `assert_chaos_resilient/4` - Verify system recovery from chaos
  - `run_chaos_suite/3` - Comprehensive chaos scenario testing
- **Supertester.PerformanceHelpers** - Performance testing and regression detection
  - `assert_performance/2` - Assert time/memory/reduction bounds
  - `assert_no_memory_leak/3` - Detect memory leaks over iterations
  - `measure_operation/1` - Measure time, memory, and CPU work
  - `measure_mailbox_growth/2` - Monitor mailbox growth
  - `assert_mailbox_stable/2` - Ensure mailbox doesn't grow unbounded
  - `compare_performance/1` - Compare multiple function performances

### Changed
- **BREAKING**: Eliminated all `Process.sleep/1` calls in production code
  - Replaced with proper `receive do after` patterns
  - Modified `OTPHelpers`, `GenServerHelpers`, `UnifiedTestFoundation`, `Assertions`
  - All timing-based waits now use receive timeouts with proper remaining time calculation
- Updated package description to emphasize chaos engineering and performance testing
- Enhanced mix.exs with better hex.pm publishing metadata

### Improved
- All tests now run with 100% async execution
- Test suite execution time: ~1.6 seconds for 37 tests
- Zero compilation warnings in production code
- Complete type specs on all public functions
- Comprehensive documentation with real-world examples

### Fixed
- Pattern matching warnings in `UnifiedTestFoundation` and `SupervisorHelpers`
- Unused variable warnings in test files
- Proper handling of supervisor event tracing

### Documentation
- Added comprehensive technical design documentation.
- Added implementation status tracking documentation.
- Enhanced README.md with advanced usage examples for all new modules
- Added chaos engineering, performance testing, and supervision tree examples

### Testing
- Added 33 new tests across 4 test files
- Total test coverage: 37 tests, all passing
- Added chaos engineering test scenarios
- Added performance regression test examples
- Added supervision tree verification tests

## [0.1.0] - 2025-07-22

### Added
- Initial release of Supertester
- Multi-repository test orchestration and execution framework
- OTP-compliant testing utilities to replace `Process.sleep/1`
- Test isolation support enabling `async: true`
- GenServer testing helpers with proper synchronization
- Supervisor testing utilities for supervision tree validation
- Performance testing framework for benchmarking and load testing
- Chaos engineering helpers for resilience testing
- Custom OTP-aware assertions
- Unified test foundation with multiple isolation modes
- Complete elimination of GenServer registration conflicts
- Zero test failure guarantee across monorepo structures

### Features
- `Supertester.UnifiedTestFoundation` - Test isolation and foundation patterns
- `Supertester.OTPHelpers` - OTP-compliant testing utilities
- `Supertester.GenServerHelpers` - GenServer-specific test patterns
- `Supertester.Assertions` - Custom OTP-aware assertions

[Unreleased]: https://github.com/nshkrdotcom/supertester/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.6.0
[0.5.1]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.5.0
[0.4.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.4.0
[0.3.1]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.3.1
[0.3.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.1.0
