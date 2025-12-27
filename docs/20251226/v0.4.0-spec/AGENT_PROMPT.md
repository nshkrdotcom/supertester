# Agent Prompt: Implement Supertester v0.4.0

## Objective

Implement Supertester v0.4.0 "Global State Isolation Suite" which adds three new modules:
- `Supertester.TelemetryHelpers`
- `Supertester.LoggerIsolation`
- `Supertester.ETSIsolation`

**Success Criteria**:
- All existing tests pass
- All new tests pass
- Zero compilation warnings
- Zero dialyzer warnings
- `mix format` produces no changes

---

## Required Reading

### Specification Documents (Read First)

Read these in order to understand what to implement:

1. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/00-overview.md`
2. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/01-telemetry-helpers.md`
3. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/02-logger-isolation.md`
4. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/03-ets-isolation.md`
5. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/04-integration.md`
6. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/05-migration-guide.md`
7. `/home/home/p/g/n/supertester/docs/20251226/v0.4.0-spec/06-api-reference.md`

### Existing Source Files (Read to Understand Patterns)

Read these to understand existing code patterns and integration points:

1. `/home/home/p/g/n/supertester/lib/supertester/ex_unit_foundation.ex`
2. `/home/home/p/g/n/supertester/lib/supertester/unified_test_foundation.ex`
3. `/home/home/p/g/n/supertester/lib/supertester/isolation_context.ex`
4. `/home/home/p/g/n/supertester/lib/supertester/otp_helpers.ex`
5. `/home/home/p/g/n/supertester/lib/supertester/telemetry.ex`
6. `/home/home/p/g/n/supertester/lib/supertester/env.ex`
7. `/home/home/p/g/n/supertester/mix.exs`

### Existing Test Files (Read to Understand Test Patterns)

1. `/home/home/p/g/n/supertester/test/supertester/ex_unit_foundation_test.exs`
2. `/home/home/p/g/n/supertester/test/supertester/otp_helpers_test.exs`
3. `/home/home/p/g/n/supertester/test/supertester/telemetry_test.exs`
4. `/home/home/p/g/n/supertester/test/test_helper.exs`

---

## Context

### Project Structure

```
/home/home/p/g/n/supertester/
├── lib/supertester/
│   ├── assertions.ex
│   ├── chaos_helpers.ex
│   ├── concurrent_harness.ex
│   ├── env.ex
│   ├── ex_unit_foundation.ex
│   ├── genserver_helpers.ex
│   ├── isolation_context.ex
│   ├── message_harness.ex
│   ├── otp_helpers.ex
│   ├── performance_helpers.ex
│   ├── property_helpers.ex
│   ├── supervisor_helpers.ex
│   ├── telemetry.ex
│   ├── testable_genserver.ex
│   └── unified_test_foundation.ex
├── test/supertester/
│   └── *.exs (test files)
├── mix.exs
├── README.md
└── CHANGELOG.md
```

### Current Version

v0.3.1 - You are implementing v0.4.0

### Dependencies

No new dependencies required. Use only:
- `:telemetry` (existing)
- `Logger` (Elixir stdlib)
- `:ets` (OTP)

---

## Implementation Instructions

### Approach: Test-Driven Development

For each module, follow this order:
1. Write the test file first
2. Run tests to see them fail
3. Implement the module
4. Run tests to see them pass
5. Run `mix format`
6. Run `mix dialyzer`
7. Fix any warnings

### Step 1: Update mix.exs Version

```elixir
# Change version to 0.4.0
def project do
  [
    version: "0.4.0",
    # ...
  ]
end
```

### Step 2: Extend IsolationContext

Update `/home/home/p/g/n/supertester/lib/supertester/isolation_context.ex`:

Add new fields to the struct as specified in `00-overview.md`:
- `telemetry_test_id`
- `telemetry_handlers`
- `logger_original_level`
- `logger_isolated?`
- `isolated_ets_tables`
- `ets_mirrors`
- `ets_injections`

### Step 3: Implement TelemetryHelpers

**Test file**: `/home/home/p/g/n/supertester/test/supertester/telemetry_helpers_test.exs`

Write tests for:
- `setup_telemetry_isolation/0`
- `attach_isolated/1` and `/2`
- `get_test_id/0` and `get_test_id!/0`
- `current_test_metadata/0` and `/1`
- `assert_telemetry/1`, `/2`, `/3` (macros)
- `refute_telemetry/1`, `/2`
- `assert_telemetry_count/2`, `/3`
- `flush_telemetry/1`
- `with_telemetry/2`, `/3`
- `emit_with_context/3`

**Implementation file**: `/home/home/p/g/n/supertester/lib/supertester/telemetry_helpers.ex`

Implement per specification in `01-telemetry-helpers.md`.

### Step 4: Implement LoggerIsolation

**Test file**: `/home/home/p/g/n/supertester/test/supertester/logger_isolation_test.exs`

Write tests for:
- `setup_logger_isolation/0` and `/1`
- `isolate_level/1` and `/2`
- `restore_level/0`
- `get_isolated_level/0`
- `isolated?/0`
- `capture_isolated/2` and `/3`
- `capture_isolated!/2` and `/3`
- `with_level/2`
- `with_level_and_capture/2`

**Implementation file**: `/home/home/p/g/n/supertester/lib/supertester/logger_isolation.ex`

Implement per specification in `02-logger-isolation.md`.

### Step 5: Implement ETSIsolation

**Test file**: `/home/home/p/g/n/supertester/test/supertester/ets_isolation_test.exs`

Write tests for:
- `setup_ets_isolation/0`, `/1` (list), `/1` (context), `/2`
- `create_isolated/1` and `/2`
- `mirror_table/1` and `/2`
- `inject_table/3` and `/4`
- `get_mirror/1` and `get_mirror!/1`
- `with_table/2` and `/3`

**Implementation file**: `/home/home/p/g/n/supertester/lib/supertester/ets_isolation.ex`

Implement per specification in `03-ets-isolation.md`.

### Step 6: Update ExUnitFoundation

Update `/home/home/p/g/n/supertester/lib/supertester/ex_unit_foundation.ex`:

Add new options as specified in `04-integration.md`:
- `telemetry_isolation: true`
- `logger_isolation: true`
- `ets_isolation: [...]`

Add setup phases that call the new modules.

### Step 7: Update CHANGELOG.md

Add v0.4.0 section documenting all new features.

---

## Verification Commands

Run after each implementation step:

```bash
# Compile with warnings as errors
mix compile --warnings-as-errors

# Run all tests
mix test

# Run specific new tests
mix test test/supertester/telemetry_helpers_test.exs
mix test test/supertester/logger_isolation_test.exs
mix test test/supertester/ets_isolation_test.exs

# Format check
mix format --check-formatted

# Dialyzer
mix dialyzer

# Credo
mix credo --strict
```

---

## Final Verification

Before marking complete, ensure:

```bash
# All pass
mix compile --warnings-as-errors && \
mix format --check-formatted && \
mix credo --strict && \
mix dialyzer && \
mix test

# Run tests multiple times to verify no flakiness
for i in {1..20}; do
  mix test --seed $RANDOM || exit 1
done
```

---

## Files to Create

| File | Type |
|------|------|
| `lib/supertester/telemetry_helpers.ex` | New module |
| `lib/supertester/logger_isolation.ex` | New module |
| `lib/supertester/ets_isolation.ex` | New module |
| `test/supertester/telemetry_helpers_test.exs` | New test |
| `test/supertester/logger_isolation_test.exs` | New test |
| `test/supertester/ets_isolation_test.exs` | New test |

## Files to Modify

| File | Change |
|------|--------|
| `lib/supertester/isolation_context.ex` | Add new struct fields |
| `lib/supertester/ex_unit_foundation.ex` | Add new options, setup phases |
| `mix.exs` | Version bump to 0.4.0 |
| `CHANGELOG.md` | Document v0.4.0 changes |

---

## Do Not

- Do NOT change existing test behavior
- Do NOT remove any existing functions
- Do NOT add new dependencies
- Do NOT modify existing module APIs (only extend)
- Do NOT create documentation files (specs are already written)
