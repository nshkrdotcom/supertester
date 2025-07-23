# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/nshkrdotcom/superlearner/releases/tag/v0.1.0