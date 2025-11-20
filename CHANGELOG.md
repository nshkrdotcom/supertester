# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  - `chaos_kill_children/3` - Random child killing in supervision trees
  - `simulate_resource_exhaustion/2` - Process/ETS/memory limit simulation
  - `assert_chaos_resilient/3` - Verify system recovery from chaos
  - `run_chaos_suite/3` - Comprehensive chaos scenario testing
- **Supertester.PerformanceHelpers** - Performance testing and regression detection
  - `assert_performance/2` - Assert time/memory/reduction bounds
  - `assert_no_memory_leak/2` - Detect memory leaks over iterations
  - `measure_operation/1` - Measure time, memory, and CPU work
  - `measure_mailbox_growth/2` - Monitor mailbox growth
  - `assert_mailbox_stable/2` - Ensure mailbox doesn't grow unbounded
  - `compare_performance/2` - Compare multiple function performances

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
- Added comprehensive technical design document (docs/technical-design-enhancement-20251007.md)
- Added implementation status tracking (docs/implementation-status-final.md)
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

[Unreleased]: https://github.com/nshkrdotcom/supertester/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.3.1
[0.3.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.1.0
