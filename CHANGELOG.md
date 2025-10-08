# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/supertester/releases/tag/v0.1.0
