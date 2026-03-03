# Supertester Quick Start

Version: 0.6.0
Last Updated: March 3, 2026

## Install

```elixir
def deps do
  [
    {:supertester, "~> 0.6.0", only: :test}
  ]
end
```

```bash
mix deps.get
```

## Prerequisites

### TestableGenServer

For `cast_and_sync/4` to work, your GenServer must handle the `:__supertester_sync__` message. Add `use Supertester.TestableGenServer` to your module:

```elixir
defmodule MyApp.Counter do
  use GenServer
  use Supertester.TestableGenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{count: 0}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:increment, state) do
    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end
end
```

This injects a `handle_call(:__supertester_sync__, ...)` clause that replies `:ok`, enabling deterministic synchronization without `Process.sleep/1`.

## 1. Deterministic GenServer Test

```elixir
defmodule MyApp.CounterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  test "increments" do
    # Start a GenServer with unique naming and automatic cleanup
    {:ok, counter} = setup_isolated_genserver(Counter)

    # Cast then synchronize — guarantees the cast was processed
    :ok = cast_and_sync(counter, :increment)

    # Assert on the server state without timing hacks
    assert_genserver_state(counter, fn s -> s.count == 1 end)
  end
end
```

### `cast_and_sync/4` behavior

- When the sync handler replies `:ok` (the default `TestableGenServer` behavior), returns bare `:ok`.
- When the sync handler replies with any other value, returns `{:ok, reply}`.
- `strict?: true`: raises `ArgumentError` when sync handling is missing.
- `strict?: false` (default): returns `{:error, :missing_sync_handler}` when missing.

## 2. Supervisor Strategy Test

```elixir
defmodule MyApp.SupervisorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, SupervisorHelpers}

  test "one_for_one strategy" do
    {:ok, sup} = setup_isolated_supervisor(MySupervisor)

    result = test_restart_strategy(sup, :one_for_one, {:kill_child, :worker_1})

    assert :worker_1 in result.restarted
  end
end
```

Notes:

- strategy mismatch raises `ArgumentError`.
- unknown child IDs in scenarios raise `ArgumentError`.
- temporary removed children are reported as not restarted.

## 3. Chaos Test

```elixir
defmodule MyApp.ChaosTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, ChaosHelpers, Assertions}

  test "survives random child kills" do
    {:ok, sup} = setup_isolated_supervisor(MySupervisor)

    report = chaos_kill_children(sup, kill_rate: 0.4, duration_ms: 500)

    assert report.supervisor_crashed == false
    assert_all_children_alive(sup)
  end
end
```

Notes:

- `chaos_kill_children/2` accepts pid or registered supervisor name.
- `report.restarted` includes observed cascade replacements (for example under `:one_for_all`).

## 4. Suite-Level Chaos Runs

```elixir
defmodule MyApp.ChaosSuiteTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, ChaosHelpers}

  test "chaos suite with deadline" do
    {:ok, sup} = setup_isolated_supervisor(MySupervisor)

    scenarios = [
      %{type: :kill_children, kill_rate: 0.3, duration_ms: 150},
      %{type: :kill_children, kill_rate: 0.5, duration_ms: 150}
    ]

    report = run_chaos_suite(sup, scenarios, timeout: 1_000)

    assert report.total_scenarios == 2
  end
end
```

Notes:

- suite deadline overruns are reported with `:timeout` and `:suite_timeout`.
- a scenario that returns `{:error, :timeout}` on its own does not stop later scenarios.

## 5. Leak Assertion

```elixir
import Supertester.Assertions

assert_no_process_leaks(fn ->
  {:ok, pid} = Agent.start_link(fn -> %{} end)
  Agent.stop(pid)
end)
```

Behavior:

- detects persistent spawned/linked leaks (including delayed descendants).
- ignores short-lived transient processes.
- propagates exceptions from the operation.

## Common Patterns

### Assert state after async operation

```elixir
:ok = cast_and_sync(server, :do_work)
assert_genserver_state(server, fn state -> state.done == true end)
```

### Multiple casts then verify

```elixir
for _ <- 1..10, do: :ok = cast_and_sync(server, :increment)
{:ok, state} = Supertester.GenServerHelpers.get_server_state_safely(server)
assert state.count == 10
```

### Supervisor child restart verification

```elixir
{:ok, sup} = setup_isolated_supervisor(MySupervisor)
result = test_restart_strategy(sup, :one_for_one, {:kill_child, :worker_1})
assert :worker_1 in result.restarted
assert result.supervisor_alive
```

## Troubleshooting

### "no handle_call/3 clause was provided" or missing sync handler errors

Your GenServer does not handle `:__supertester_sync__`. Add `use Supertester.TestableGenServer` to your module.

### Tests fail with `{:error, :noproc}`

The GenServer has crashed or been stopped before your assertion. Check for unhandled messages or invalid state transitions in your GenServer.

### Tests pass individually but fail when run together

You may be using named processes without isolation. Use `setup_isolated_genserver/3` which generates unique names, or use `Supertester.ExUnitFoundation` with `:full_isolation`.

## Next

- [API Guide](API_GUIDE.md)
- [Manual](MANUAL.md)
- [Docs Index](DOCS_INDEX.md)
