# Supertester

Multi-repository test orchestration and execution framework for Elixir monorepo structures.

## Overview

Supertester provides centralized test management, execution, and reporting across multiple Elixir repositories in a monorepo structure. It eliminates common OTP testing issues like GenServer registration conflicts, improper synchronization using `Process.sleep/1`, and test interdependence.

## Key Features

- **OTP-Compliant Testing**: Replace `Process.sleep/1` with proper synchronization
- **Test Isolation**: Enable `async: true` through process isolation
- **GenServer Helpers**: Specialized utilities for GenServer testing
- **Supervisor Testing**: Supervision tree and strategy testing utilities  
- **Performance Testing**: Benchmarking and load testing framework
- **Chaos Engineering**: Resilience and failure injection testing
- **Zero Test Failures**: Eliminate race conditions and process conflicts

## Installation

Add supertester as a test dependency in your `mix.exs`:

```elixir
def deps do
  [
    {:supertester, path: "../supertester", only: :test}
  ]
end
```

## Usage

### Basic GenServer Testing

```elixir
defmodule MyApp.MyGenServerTest do
  use ExUnit.Case, async: true
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  describe "my genserver functionality" do
    setup do
      {:ok, server} = setup_isolated_genserver(MyGenServer, "basic_test")
      %{server: server}
    end

    test "server responds to calls", %{server: server} do
      assert_genserver_responsive(server)
      {:ok, response} = call_with_timeout(server, :get_state)
      assert response == %{counter: 0}
    end

    test "server handles casts properly", %{server: server} do
      :ok = cast_and_sync(server, {:increment, 5})
      assert_genserver_state(server, %{counter: 5})
    end
  end
end
```

### Supervisor Testing

```elixir
defmodule MyApp.MySupervisorTest do
  use ExUnit.Case, async: true
  import Supertester.OTPHelpers
  import Supertester.SupervisorHelpers
  import Supertester.Assertions

  describe "supervisor behavior" do
    setup do
      {:ok, supervisor} = setup_isolated_supervisor(MySupervisor, "supervisor_test")
      %{supervisor: supervisor}
    end

    test "supervisor manages children correctly", %{supervisor: supervisor} do
      assert_all_children_alive(supervisor)
      assert_child_count(supervisor, 3)
    end
  end
end
```

### Advanced Testing with Isolation

```elixir
defmodule MyApp.AdvancedTest do
  use ExUnit.Case
  use Supertester.UnifiedTestFoundation, isolation: :full_isolation

  test "full isolation testing", context do
    # Test runs with complete process and ETS isolation
    # Multiple tests can run concurrently without conflicts
  end
end
```

## Core Modules

- **`Supertester.UnifiedTestFoundation`** - Test isolation and foundation patterns
- **`Supertester.OTPHelpers`** - OTP-compliant testing utilities
- **`Supertester.GenServerHelpers`** - GenServer-specific test patterns
- **`Supertester.SupervisorHelpers`** - Supervision tree testing utilities
- **`Supertester.MessageHelpers`** - Message tracing and ETS management
- **`Supertester.PerformanceHelpers`** - Benchmarking and load testing
- **`Supertester.ChaosHelpers`** - Chaos engineering and resilience testing
- **`Supertester.DataGenerators`** - Test data and scenario generation
- **`Supertester.Assertions`** - Custom OTP-aware assertions

## Migration from Legacy Patterns

### Before (with Process.sleep)

```elixir
test "legacy pattern with sleep" do
  {:ok, server} = GenServer.start_link(MyServer, [], name: MyServer)
  GenServer.cast(MyServer, :increment)
  :timer.sleep(10)  # BAD: Timing-based synchronization
  
  {:ok, state} = GenServer.call(MyServer, :get_state)
  assert state.counter == 1
  
  GenServer.stop(MyServer)
end
```

### After (with Supertester)

```elixir
test "improved pattern with supertester" do
  {:ok, server} = setup_isolated_genserver(MyServer, "test")
  :ok = cast_and_sync(server, :increment)  # GOOD: Deterministic synchronization
  
  assert_genserver_state(server, fn state -> state.counter == 1 end)
  # Automatic cleanup handled by supertester
end
```

## Testing Strategy

### Test Organization

```
test/
├── unit/               # Individual module tests
├── integration/        # Cross-module integration tests  
├── performance/        # Performance and load tests
└── support/           # Test helpers and utilities
```

### Best Practices

1. **Always use `async: true`** with proper isolation
2. **Replace `Process.sleep/1`** with synchronization helpers
3. **Use unique process names** via isolation helpers
4. **Test supervision strategies** explicitly
5. **Include performance assertions** in critical paths
6. **Add chaos testing** for resilience validation

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Run with coverage
mix test --cover

# Check code quality
mix credo
mix dialyzer
```

## Contributing

1. Follow OTP best practices in all test helpers
2. Ensure all new features include comprehensive tests
3. Maintain documentation for all public functions
4. Add performance considerations for new helpers

## License

Apache License 2.0