# Supertester Examples

This folder contains full Mix applications that demonstrate Supertester in real test suites.

## Available Examples

- `echo_lab/` - Compact OTP app with a comprehensive test suite covering every Supertester module.

## Running an Example

```bash
cd examples/echo_lab
mix deps.get
mix test
```

Each example uses a path dependency pointing back to the Supertester repo root, so you can edit
Supertester and immediately see the behavior in the example tests.
