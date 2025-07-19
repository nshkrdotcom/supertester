# Supertester - Multi-Repository Test Infrastructure Overhaul

## Project Overview

Supertester is a standalone test orchestration and execution framework designed to unify testing standards across 6 Elixir repositories (arsenal, apex, apex_ui, arsenal_plug, sandbox, cluster_test) in a monorepo structure.

## Project Specifications

The complete project specifications are located in the `.kiro` directory:

- **Requirements**: [`../.kiro/specs/multi-repo-test-infrastructure-overhaul/requirements.md`](../.kiro/specs/multi-repo-test-infrastructure-overhaul/requirements.md)
- **Design**: [`../.kiro/specs/multi-repo-test-infrastructure-overhaul/design.md`](../.kiro/specs/multi-repo-test-infrastructure-overhaul/design.md)  
- **Tasks**: [`../.kiro/specs/multi-repo-test-infrastructure-overhaul/tasks.md`](../.kiro/specs/multi-repo-test-infrastructure-overhaul/tasks.md)

## Current Issues Being Addressed

- **22 test failures in Arsenal** due to GenServer registration conflicts
- **Improper synchronization** using `Process.sleep/1` instead of OTP patterns
- **Test interdependence** requiring `async: false`
- **Lack of test isolation** causing race conditions

## Key Objectives

1. **Unified Testing**: Provide shared test helpers and consistent patterns across all repositories
2. **OTP Compliance**: Eliminate test failures caused by GenServer conflicts and improper synchronization
3. **Test Independence**: Ensure tests run reliably in parallel without race conditions
4. **Performance**: Target <30 second test execution per repository with zero failures
5. **Developer Experience**: Consistent APIs and patterns for easier cross-repository development

## Implementation Strategy

Supertester will be used as a path dependency (`../supertester`) by all 6 repositories, providing:

- **SuperTester.UnifiedTestFoundation** - Isolation modes and test setup
- **SuperTester.OTPHelpers** - OTP-compliant testing utilities  
- **SuperTester.GenServerHelpers** - GenServer-specific test patterns
- **SuperTester.SupervisorHelpers** - Supervision tree testing
- **SuperTester.MessageHelpers** - Message tracing and ETS management
- **SuperTester.PerformanceHelpers** - Benchmarking and load testing
- **SuperTester.ChaosHelpers** - Chaos engineering and resilience testing
- **SuperTester.DataGenerators** - Test data and scenario generation
- **SuperTester.Assertions** - Custom OTP-aware assertions

## Success Metrics

- **Zero test failures** across all 6 repositories
- **All tests use `async: true`** with proper isolation
- **Zero `Process.sleep/1` usage** in test code
- **Test execution under 30 seconds** per repository
- **Consistent test patterns** across all repositories