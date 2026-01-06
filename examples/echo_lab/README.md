# EchoLab Example App

EchoLab is a tiny OTP application whose test suite exercises every Supertester feature end to end.
It is intentionally small so the tests stay focused on Supertester itself rather than app logic.

## What This Example Covers

The EchoLab test suite demonstrates:

- `Supertester.ExUnitFoundation` isolation, tags, telemetry/log/ETS extensions
- `Supertester.UnifiedTestFoundation` API (including contamination detection)
- `Supertester.Env` custom environment module
- `Supertester.TestableGenServer` sync handler injection
- `Supertester.OTPHelpers` for isolated GenServers and supervisors
- `Supertester.GenServerHelpers` for state access, sync casts, concurrency, and recovery
- `Supertester.SupervisorHelpers` for restart strategy checks and tree validation
- `Supertester.Assertions` for OTP-aware assertions and leak checks
- `Supertester.PerformanceHelpers` for performance and mailbox monitoring
- `Supertester.ChaosHelpers` for crash injection and chaos suites
- `Supertester.ConcurrentHarness` and `Supertester.PropertyHelpers`
- `Supertester.MessageHarness` for mailbox tracing
- `Supertester.Telemetry` and `Supertester.TelemetryHelpers`
- `Supertester.LoggerIsolation` and `Supertester.ETSIsolation`

## Running the Tests

```bash
cd examples/echo_lab
mix deps.get
mix test
```

## Layout

- `lib/` contains a small counter, workers, supervisors, and ETS helpers.
- `test/` contains focused tests that map directly to Supertester modules.
- `test/support/` contains the `TestableCounter` used by sync and harness examples.
