# Supertester Quick Start Guide
**Version**: 0.2.0

Get up and running with Supertester in 5 minutes!

---

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:supertester, "~> 0.2.0", only: :test}
  ]
end
```

Run:
```bash
mix deps.get
```

---

## 5-Minute Tutorial

### Step 1: Basic GenServer Test (30 seconds)

```elixir
defmodule MyApp.CounterTest do
  use ExUnit.Case, async: true
  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  test "counter works" do
    {:ok, counter} = setup_isolated_genserver(Counter)

    :ok = cast_and_sync(counter, :increment)
    :ok = cast_and_sync(counter, :increment)

    assert_genserver_state(counter, fn s -> s.count == 2 end)
  end
end
```

**Run**: `mix test`
**Result**: Fast, reliable, parallel test ✅

---

### Step 2: Add Chaos Testing (1 minute)

```elixir
test "system survives worker crashes" do
  import Supertester.ChaosHelpers

  {:ok, supervisor} = setup_isolated_supervisor(WorkerSupervisor)

  # Kill 50% of workers randomly
  report = chaos_kill_children(supervisor,
    kill_rate: 0.5,
    duration_ms: 2000
  )

  # Verify recovery
  assert Process.alive?(supervisor)
  assert_all_children_alive(supervisor)
end
```

**Run**: `mix test`
**Result**: Chaos test validates resilience ✅

---

### Step 3: Add Performance Testing (1 minute)

```elixir
test "meets performance SLA" do
  import Supertester.PerformanceHelpers

  {:ok, api} = setup_isolated_genserver(APIServer)

  assert_performance(
    fn -> APIServer.get_user(api, 1) end,
    max_time_ms: 100,
    max_memory_bytes: 1_000_000
  )
end
```

**Run**: `mix test`
**Result**: Performance regression protection ✅

---

### Step 4: Test Supervision Strategy (1 minute)

```elixir
test "one_for_one restarts only failed child" do
  import Supertester.SupervisorHelpers

  {:ok, supervisor} = setup_isolated_supervisor(MySupervisor)

  result = test_restart_strategy(supervisor, :one_for_one,
    {:kill_child, :worker_1}
  )

  assert result.restarted == [:worker_1]
  assert :worker_2 in result.not_restarted
end
```

**Run**: `mix test`
**Result**: Supervision strategy verified ✅

---

### Step 5: Make Your GenServer Testable (30 seconds)

In your GenServer:

```elixir
defmodule MyApp.MyServer do
  use GenServer
  use Supertester.TestableGenServer  # ← Add this line!

  # Rest of your implementation
end
```

Now in tests:

```elixir
test "async operations are deterministic" do
  {:ok, server} = MyServer.start_link()

  GenServer.cast(server, :async_operation)
  GenServer.call(server, :__supertester_sync__)  # ← No more sleep!

  # Now safe to verify
  assert_genserver_state(server, fn s -> s.done == true end)
end
```

**Run**: `mix test`
**Result**: No more Process.sleep! ✅

---

## 🎯 Common Use Cases

### Use Case 1: Replace Process.sleep

**Before**:
```elixir
GenServer.cast(server, :operation)
Process.sleep(50)  # Fragile!
state = :sys.get_state(server)
assert state.done == true
```

**After**:
```elixir
:ok = cast_and_sync(server, :operation)
assert_genserver_state(server, fn s -> s.done == true end)
```

---

### Use Case 2: Test System Resilience

```elixir
test "payment system handles failures" do
  {:ok, payment_supervisor} = setup_isolated_supervisor(PaymentSupervisor)

  # Inject chaos
  chaos_kill_children(payment_supervisor, kill_rate: 0.3, duration_ms: 5000)

  # Verify system survived and recovered
  assert Process.alive?(payment_supervisor)
  assert_all_children_alive(payment_supervisor)
  assert PaymentSystem.no_lost_transactions?(payment_supervisor)
end
```

---

### Use Case 3: Performance SLA Testing

```elixir
test "API endpoints meet SLA" do
  {:ok, api} = setup_isolated_genserver(APIServer)

  # Critical endpoints must be fast
  assert_performance(
    fn -> APIServer.get_user(api, 1) end,
    max_time_ms: 50
  )

  assert_performance(
    fn -> APIServer.search(api, "query") end,
    max_time_ms: 200
  )
end
```

---

### Use Case 4: Memory Leak Detection

```elixir
test "worker doesn't leak memory" do
  {:ok, worker} = setup_isolated_genserver(Worker)

  # Run 100k operations
  assert_no_memory_leak(100_000, fn ->
    Worker.process(worker, random_message())
  end)
end
```

---

### Use Case 5: Supervision Tree Validation

```elixir
test "supervision tree is correctly structured" do
  {:ok, root} = setup_isolated_supervisor(RootSupervisor)

  assert_supervision_tree_structure(root, %{
    supervisor: RootSupervisor,
    strategy: :one_for_one,
    children: [
      {:cache, CacheServer},
      {:api, APIServer},
      {:workers, WorkerPoolSupervisor}
    ]
  })
end
```

---

## 🎨 Import Patterns

Choose the modules you need:

```elixir
# Basic OTP testing
import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

# Chaos testing
import Supertester.{ChaosHelpers, SupervisorHelpers}

# Performance testing
import Supertester.PerformanceHelpers

# Everything
import Supertester.{
  OTPHelpers,
  GenServerHelpers,
  SupervisorHelpers,
  ChaosHelpers,
  PerformanceHelpers,
  Assertions
}
```

---

## 🔑 Key Concepts

### 1. Isolation
Always use isolation for parallel tests:

```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. No Process.sleep
Use proper synchronization:

```elixir
# ❌ Never do this
GenServer.cast(server, :op)
Process.sleep(50)

# ✅ Do this instead
cast_and_sync(server, :op)
```

### 3. Automatic Cleanup
`setup_isolated_*` functions handle cleanup:

```elixir
test "example" do
  {:ok, server} = setup_isolated_genserver(MyServer)
  # Test logic
  # No need to manually stop - automatic cleanup!
end
```

### 4. Expressive Assertions
Use OTP-aware assertions:

```elixir
# ❌ Verbose
state = :sys.get_state(server)
assert state.count == 5

# ✅ Expressive
assert_genserver_state(server, %{count: 5})
```

---

## 🚀 Next Steps

### After Tutorial
1. Read [API_GUIDE.md](API_GUIDE.md) for complete reference
2. Review examples in `test/supertester/` directory
3. Try chaos and performance testing on your code
4. Join the community and contribute!

### Advanced Topics
- Chaos scenario customization
- Performance regression testing in CI/CD
- Complex supervision tree testing
- Custom assertions

---

## 💡 Tips & Tricks

### Tip 1: Start Simple
Begin with basic isolation and assertions, add chaos/performance later.

### Tip 2: Use TestableGenServer Everywhere
Add `use Supertester.TestableGenServer` to all your GenServers from the start.

### Tip 3: Chaos Test Critical Paths
Focus chaos testing on critical systems (payments, user data, etc.).

### Tip 4: Performance Test in CI/CD
Run performance tests in CI to catch regressions early.

### Tip 5: Read the Source
Module implementations are well-documented - great learning resource!

---

## 🆘 Troubleshooting

### Tests still flaky?
→ Make sure you're using `cast_and_sync` instead of `cast` + sleep

### Name conflicts?
→ Use `setup_isolated_genserver` which generates unique names

### Supervisor tests failing?
→ Use `wait_for_supervisor_stabilization` after causing failures

### Chaos tests too aggressive?
→ Reduce `kill_rate` or `duration_ms` parameters

---

## 📖 Full Documentation

- **API Reference**: [API_GUIDE.md](API_GUIDE.md)
- **Technical Design**: [technical-design-enhancement-20251007.md](technical-design-enhancement-20251007.md)
- **Release Notes**: [RELEASE_0.2.0_SUMMARY.md](RELEASE_0.2.0_SUMMARY.md)
- **Main README**: [../README.md](../README.md)

---

**Time to First Test**: < 5 minutes
**Time to Production**: < 1 hour
**Learning Curve**: Gentle (builds on ExUnit knowledge)

**Ready to build bulletproof Elixir systems? Start testing with Supertester!** 🚀
