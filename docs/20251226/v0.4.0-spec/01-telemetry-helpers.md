# Supertester.TelemetryHelpers Specification

## Module Purpose

Provide async-safe telemetry testing by isolating telemetry events to only those emitted within the context of a specific test, preventing cross-test pollution in concurrent test execution.

---

## The Problem in Detail

### Telemetry is Global by Design

The `:telemetry` library uses a global handler registry. When you call `:telemetry.attach/4`, the handler receives events from **all processes** in the VM:

```elixir
# In test A
:telemetry.attach("test-a-handler", [:myapp, :request], &handler/4, self())

# In test B (running concurrently)
:telemetry.execute([:myapp, :request], %{latency: 100}, %{request_id: "test-b-id"})

# Test A's handler receives Test B's event!
```

### Current Workarounds are Insufficient

**Pattern matching in assert_receive**:
```elixir
# This helps but is verbose and error-prone
assert_receive {:telemetry, [:myapp, :request], _, %{request_id: ^expected_id}}
```

**Using unique request IDs**:
```elixir
# Requires threading IDs through all code paths
request_id = "test-#{System.unique_integer()}"
```

**Running tests with `async: false`**:
```elixir
# Works but destroys test suite performance
use ExUnit.Case, async: false
```

---

## Solution: Test-Scoped Telemetry

### Core Concept: Telemetry Test ID

Each test gets a unique `telemetry_test_id`. Events are tagged with this ID at emission time, and handlers filter to only receive events with matching IDs.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Test Process                             │
│  telemetry_test_id = 12345                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    attach_isolated/2                             │
│  Registers handler that checks metadata.supertester_test_id     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Application Code                              │
│  Uses emit_with_context/3 OR code is instrumented to include    │
│  supertester_test_id from process dictionary                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Handler Filter                                │
│  event.metadata.supertester_test_id == test_id ? deliver : skip │
└─────────────────────────────────────────────────────────────────┘
```

---

## API Specification

### Types

```elixir
@type event :: [atom()]
@type measurements :: map()
@type metadata :: map()
@type handler_id :: String.t()
@type test_id :: integer()
@type telemetry_message :: {:telemetry, event(), measurements(), metadata()}

@type attach_opts :: [
  filter_key: atom(),           # Metadata key to filter on (default: :supertester_test_id)
  passthrough: boolean(),       # Also deliver events without test_id (default: false)
  buffer: boolean(),            # Buffer events instead of sending immediately (default: false)
  transform: (telemetry_message() -> term())  # Transform before delivery
]

@type assert_opts :: [
  timeout: pos_integer(),       # Assertion timeout in ms (default: 1000)
  count: pos_integer(),         # Expect exactly N events (default: 1)
  within: pos_integer()         # All events must arrive within N ms
]
```

### Core Functions

#### `setup_telemetry_isolation/0`

Initialize telemetry isolation for the current test. Called automatically by ExUnitFoundation when `telemetry_isolation: true`.

```elixir
@spec setup_telemetry_isolation() :: {:ok, test_id()}
@spec setup_telemetry_isolation(IsolationContext.t()) :: {:ok, test_id(), IsolationContext.t()}

def setup_telemetry_isolation do
  test_id = System.unique_integer([:positive, :monotonic])
  Process.put(:supertester_telemetry_test_id, test_id)
  {:ok, test_id}
end

def setup_telemetry_isolation(%IsolationContext{} = ctx) do
  {:ok, test_id} = setup_telemetry_isolation()
  updated_ctx = %{ctx | telemetry_test_id: test_id}
  {:ok, test_id, updated_ctx}
end
```

#### `attach_isolated/2`

Attach a telemetry handler that only receives events matching the current test's ID.

```elixir
@spec attach_isolated(event() | [event()], attach_opts()) :: {:ok, handler_id()}

def attach_isolated(events, opts \\ []) do
  events = List.wrap(events)
  test_id = get_test_id!()
  handler_id = "supertester-telemetry-#{test_id}-#{System.unique_integer()}"
  parent = self()
  filter_key = Keyword.get(opts, :filter_key, :supertester_test_id)
  passthrough = Keyword.get(opts, :passthrough, false)
  buffer = Keyword.get(opts, :buffer, false)
  transform = Keyword.get(opts, :transform, &Function.identity/1)

  handler_fn = fn event, measurements, metadata, _config ->
    event_test_id = Map.get(metadata, filter_key)

    should_deliver =
      event_test_id == test_id or
      (passthrough and is_nil(event_test_id))

    if should_deliver do
      message = transform.({:telemetry, event, measurements, metadata})

      if buffer do
        buffer_event(parent, message)
      else
        send(parent, message)
      end

      emit_delivered(event, test_id)
    else
      emit_filtered(event, event_test_id, test_id)
    end
  end

  :ok = :telemetry.attach_many(handler_id, events, handler_fn, nil)

  Supertester.Env.on_exit(fn ->
    :telemetry.detach(handler_id)
    emit_detached(handler_id)
  end)

  emit_attached(handler_id, events)
  {:ok, handler_id}
end
```

#### `get_test_id/0` and `get_test_id!/0`

Retrieve the current test's telemetry ID.

```elixir
@spec get_test_id() :: test_id() | nil
@spec get_test_id!() :: test_id()

def get_test_id do
  Process.get(:supertester_telemetry_test_id)
end

def get_test_id! do
  case get_test_id() do
    nil -> raise "Telemetry isolation not set up. Call setup_telemetry_isolation/0 first."
    id -> id
  end
end
```

#### `current_test_metadata/0`

Get metadata map with current test's ID for inclusion in telemetry events.

```elixir
@spec current_test_metadata() :: map()
@spec current_test_metadata(map()) :: map()

def current_test_metadata do
  case get_test_id() do
    nil -> %{}
    id -> %{supertester_test_id: id}
  end
end

def current_test_metadata(existing) when is_map(existing) do
  Map.merge(existing, current_test_metadata())
end
```

---

### Assertion Functions

#### `assert_telemetry/2`

Assert that a telemetry event matching the pattern was received.

```elixir
@spec assert_telemetry(event() | (event() -> boolean()), assert_opts()) :: telemetry_message()

defmacro assert_telemetry(event_pattern, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 1000)

  quote do
    test_id = Supertester.TelemetryHelpers.get_test_id!()

    receive do
      {:telemetry, event, measurements, %{supertester_test_id: ^test_id} = metadata} = msg
      when unquote(match_event_pattern(event_pattern, quote(do: event))) ->
        msg
    after
      unquote(timeout) ->
        raise ExUnit.AssertionError,
          message: "Expected telemetry event matching #{inspect(unquote(event_pattern))} " <>
                   "with test_id #{test_id}, but none received within #{unquote(timeout)}ms"
    end
  end
end
```

#### `assert_telemetry/3`

Assert telemetry with specific metadata pattern.

```elixir
@spec assert_telemetry(event(), map() | (map() -> boolean()), assert_opts()) :: telemetry_message()

defmacro assert_telemetry(event_pattern, metadata_pattern, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 1000)

  quote do
    test_id = Supertester.TelemetryHelpers.get_test_id!()

    receive do
      {:telemetry, event, measurements, %{supertester_test_id: ^test_id} = metadata} = msg
      when unquote(match_event_pattern(event_pattern, quote(do: event))) and
           unquote(match_metadata_pattern(metadata_pattern, quote(do: metadata))) ->
        msg
    after
      unquote(timeout) ->
        raise ExUnit.AssertionError,
          message: "Expected telemetry event #{inspect(unquote(event_pattern))} " <>
                   "with metadata matching #{inspect(unquote(metadata_pattern))}, " <>
                   "but none received within #{unquote(timeout)}ms"
    end
  end
end
```

#### `refute_telemetry/2`

Assert that NO telemetry event matching the pattern was received.

```elixir
@spec refute_telemetry(event(), assert_opts()) :: :ok

defmacro refute_telemetry(event_pattern, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 100)

  quote do
    test_id = Supertester.TelemetryHelpers.get_test_id!()

    receive do
      {:telemetry, event, _, %{supertester_test_id: ^test_id}} = msg
      when unquote(match_event_pattern(event_pattern, quote(do: event))) ->
        raise ExUnit.AssertionError,
          message: "Expected NO telemetry event matching #{inspect(unquote(event_pattern))}, " <>
                   "but received: #{inspect(msg)}"
    after
      unquote(timeout) ->
        :ok
    end
  end
end
```

#### `assert_telemetry_count/3`

Assert exactly N telemetry events were received.

```elixir
@spec assert_telemetry_count(event(), pos_integer(), assert_opts()) :: [telemetry_message()]

def assert_telemetry_count(event_pattern, expected_count, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 1000)
  test_id = get_test_id!()

  events = collect_telemetry_events(event_pattern, test_id, expected_count, timeout)
  actual_count = length(events)

  if actual_count != expected_count do
    raise ExUnit.AssertionError,
      message: "Expected #{expected_count} telemetry events matching #{inspect(event_pattern)}, " <>
               "but received #{actual_count}"
  end

  events
end
```

---

### Utility Functions

#### `flush_telemetry/1`

Remove all telemetry messages from the process mailbox.

```elixir
@spec flush_telemetry(event() | :all) :: [telemetry_message()]

def flush_telemetry(:all) do
  flush_telemetry_loop([])
end

def flush_telemetry(event_pattern) do
  test_id = get_test_id()
  flush_telemetry_loop([], event_pattern, test_id)
end

defp flush_telemetry_loop(acc) do
  receive do
    {:telemetry, _, _, _} = msg -> flush_telemetry_loop([msg | acc])
  after
    0 -> Enum.reverse(acc)
  end
end
```

#### `with_telemetry/3`

Execute a function and capture all telemetry events emitted.

```elixir
@spec with_telemetry(event() | [event()], (-> result), attach_opts()) ::
  {result, [telemetry_message()]} when result: term()

def with_telemetry(events, fun, opts \\ []) do
  {:ok, _handler_id} = attach_isolated(events, Keyword.put(opts, :buffer, true))

  result = fun.()

  # Small delay to ensure all async events are buffered
  Process.sleep(10)

  events = flush_buffer()
  {result, events}
end
```

#### `emit_with_context/3`

Emit a telemetry event with the current test's ID automatically included.

```elixir
@spec emit_with_context(event(), measurements(), metadata()) :: :ok

def emit_with_context(event, measurements \\ %{}, metadata \\ %{}) do
  enriched_metadata = current_test_metadata(metadata)
  :telemetry.execute(event, measurements, enriched_metadata)
end
```

---

### Integration with Application Code

For telemetry isolation to work, application code must include the test ID in emitted events. There are two approaches:

#### Approach 1: Automatic Context Propagation (Recommended)

Application code checks for test context and includes it:

```elixir
# In application code
defmodule MyApp.Telemetry do
  def emit(event, measurements, metadata) do
    # Include test context if present (noop in production)
    enriched = maybe_add_test_context(metadata)
    :telemetry.execute(event, measurements, enriched)
  end

  defp maybe_add_test_context(metadata) do
    case Process.get(:supertester_telemetry_test_id) do
      nil -> metadata
      id -> Map.put(metadata, :supertester_test_id, id)
    end
  end
end
```

#### Approach 2: Config-Based Injection

Use application config to enable test context injection:

```elixir
# In application code
defmodule MyApp.Telemetry do
  def emit(event, measurements, metadata) do
    enriched = if Application.get_env(:myapp, :test_mode) do
      maybe_add_test_context(metadata)
    else
      metadata
    end
    :telemetry.execute(event, measurements, enriched)
  end
end

# In config/test.exs
config :myapp, test_mode: true
```

#### Approach 3: Passthrough Mode

For code you can't modify, use `passthrough: true` to also receive events without test IDs:

```elixir
# In test
attach_isolated([:external_lib, :event], passthrough: true)

# Then filter in assertions as needed
assert_receive {:telemetry, [:external_lib, :event], _, metadata}
# May receive events from other tests - handle accordingly
```

---

## Usage Examples

### Basic Usage

```elixir
defmodule MyApp.ServiceTest do
  use Supertester.ExUnitFoundation,
    isolation: :full_isolation,
    telemetry_isolation: true

  test "emits request telemetry", %{isolation_context: ctx} do
    # Handler automatically filters by test_id
    {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :request, :done])

    # Make request (code must include test context)
    MyApp.Service.make_request(%{id: "test-123"})

    # Assert - only receives events from THIS test
    assert_telemetry [:myapp, :request, :done], %{request_id: "test-123"}
  end

  test "concurrent test doesn't interfere" do
    {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :request, :done])

    MyApp.Service.make_request(%{id: "other-123"})

    # This assertion won't receive events from the test above
    assert_telemetry [:myapp, :request, :done], %{request_id: "other-123"}
  end
end
```

### Capturing Multiple Events

```elixir
test "captures all request events" do
  {result, events} = TelemetryHelpers.with_telemetry(
    [[:myapp, :request, :start], [:myapp, :request, :done]],
    fn ->
      MyApp.Service.make_request(%{id: "test"})
    end
  )

  assert result == :ok
  assert length(events) == 2
  assert Enum.any?(events, fn {:telemetry, event, _, _} -> event == [:myapp, :request, :start] end)
  assert Enum.any?(events, fn {:telemetry, event, _, _} -> event == [:myapp, :request, :done] end)
end
```

### Asserting Event Count

```elixir
test "emits exactly 3 retry events" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :retry])

  MyApp.Service.make_request_with_retries(%{max_retries: 3})

  events = TelemetryHelpers.assert_telemetry_count([:myapp, :retry], 3)

  # Verify retry attempts are sequential
  attempts = Enum.map(events, fn {:telemetry, _, _, %{attempt: n}} -> n end)
  assert attempts == [1, 2, 3]
end
```

### Refuting Unwanted Events

```elixir
test "successful request doesn't emit error telemetry" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :error])

  assert {:ok, _} = MyApp.Service.make_request(%{id: "good"})

  refute_telemetry [:myapp, :error]
end
```

---

## Implementation Details

### Buffering

When `buffer: true`, events are stored in an Agent instead of sent directly:

```elixir
defp buffer_event(parent, message) do
  buffer_name = :"supertester_telemetry_buffer_#{:erlang.phash2(parent)}"

  case Process.whereis(buffer_name) do
    nil ->
      {:ok, _} = Agent.start_link(fn -> [] end, name: buffer_name)
      Agent.update(buffer_name, &[message | &1])
    _pid ->
      Agent.update(buffer_name, &[message | &1])
  end
end

defp flush_buffer do
  buffer_name = :"supertester_telemetry_buffer_#{:erlang.phash2(self())}"

  case Process.whereis(buffer_name) do
    nil -> []
    pid ->
      events = Agent.get(pid, &Enum.reverse/1)
      Agent.stop(pid)
      events
  end
end
```

### Cleanup

All handlers are automatically detached via `on_exit`:

```elixir
Supertester.Env.on_exit(fn ->
  :telemetry.detach(handler_id)
end)
```

### Telemetry Events Emitted

The module emits its own telemetry for observability:

```elixir
[:supertester, :telemetry, :handler, :attached]
  measurements: %{}
  metadata: %{handler_id: String.t(), events: [event()], test_id: integer()}

[:supertester, :telemetry, :handler, :detached]
  measurements: %{}
  metadata: %{handler_id: String.t()}

[:supertester, :telemetry, :event, :filtered]
  measurements: %{count: 1}
  metadata: %{event: event(), event_test_id: integer() | nil, handler_test_id: integer()}

[:supertester, :telemetry, :event, :delivered]
  measurements: %{count: 1}
  metadata: %{event: event(), test_id: integer()}
```

---

## Testing the Module Itself

```elixir
defmodule Supertester.TelemetryHelpersTest do
  use ExUnit.Case, async: true

  alias Supertester.TelemetryHelpers

  describe "attach_isolated/2" do
    test "only receives events with matching test_id" do
      {:ok, _test_id} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _handler} = TelemetryHelpers.attach_isolated([:test, :event])

      # Emit with correct test_id
      TelemetryHelpers.emit_with_context([:test, :event], %{value: 1}, %{source: "correct"})

      # Emit without test_id (simulates other test)
      :telemetry.execute([:test, :event], %{value: 2}, %{source: "wrong"})

      # Should only receive the first event
      assert_receive {:telemetry, [:test, :event], %{value: 1}, %{source: "correct"}}
      refute_receive {:telemetry, [:test, :event], %{value: 2}, _}, 50
    end

    test "passthrough mode receives events without test_id" do
      {:ok, _test_id} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _handler} = TelemetryHelpers.attach_isolated([:test, :event], passthrough: true)

      # Emit without test_id
      :telemetry.execute([:test, :event], %{value: 1}, %{source: "no_id"})

      assert_receive {:telemetry, [:test, :event], %{value: 1}, %{source: "no_id"}}
    end
  end

  describe "assert_telemetry/2" do
    test "succeeds when matching event received" do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _} = TelemetryHelpers.attach_isolated([:test, :success])

      TelemetryHelpers.emit_with_context([:test, :success], %{}, %{key: "value"})

      msg = TelemetryHelpers.assert_telemetry([:test, :success])
      assert {:telemetry, [:test, :success], _, %{key: "value"}} = msg
    end

    test "fails when no matching event received" do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _} = TelemetryHelpers.attach_isolated([:test, :missing])

      assert_raise ExUnit.AssertionError, fn ->
        TelemetryHelpers.assert_telemetry([:test, :missing], timeout: 50)
      end
    end
  end
end
```

---

## Migration Notes

### From Manual Telemetry Testing

Before:
```elixir
test "emits telemetry" do
  handler_id = "test-#{System.unique_integer()}"
  :telemetry.attach(handler_id, [:myapp, :event], &send_to_test/4, self())
  on_exit(fn -> :telemetry.detach(handler_id) end)

  do_work()

  assert_receive {:telemetry, [:myapp, :event], _, %{id: expected_id}}
end
```

After:
```elixir
test "emits telemetry" do
  {:ok, _} = TelemetryHelpers.attach_isolated([:myapp, :event])

  do_work()

  assert_telemetry [:myapp, :event], %{id: expected_id}
end
```

### From HTTPCase Pattern

If your codebase has a pattern like `Tinkex.HTTPCase.attach_telemetry/1`, replace with:

```elixir
# In http_case.ex or equivalent
def attach_telemetry(events) do
  Supertester.TelemetryHelpers.attach_isolated(events)
end
```
