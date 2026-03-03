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

## 1. Deterministic GenServer Test

```elixir
defmodule MyApp.CounterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

  test "increments" do
    {:ok, counter} = setup_isolated_genserver(Counter)

    :ok = cast_and_sync(counter, :increment)

    assert_genserver_state(counter, fn s -> s.count == 1 end)
  end
end
```

### `cast_and_sync/4` behavior

- `strict?: true`: raises `ArgumentError` when sync handling is missing.
- `strict?: false` (default): returns `{:error, :missing_sync_handler}` when missing.
- If sync call is handled and replies with any value, return is `{:ok, reply}`.

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
scenarios = [
  %{type: :kill_children, kill_rate: 0.3, duration_ms: 150},
  %{type: :kill_children, kill_rate: 0.5, duration_ms: 150}
]

report = Supertester.ChaosHelpers.run_chaos_suite(supervisor, scenarios, timeout: 1_000)
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

## Next

- [API Guide](API_GUIDE.md)
- [Manual](MANUAL.md)
- [Docs Index](DOCS_INDEX.md)
