Here’s a prescriptive, agent-ready plan to evolve Supertester into an even stronger concurrent-testing harness, while keeping the current API working by default and introducing breaking changes only behind flags / in a later major release.

I’ll structure it as phases with concrete tasks and acceptance criteria so you (or an agent) can drive implementation straight from this.

---

## 0. Goals & Constraints

### Primary goal

> **Make Supertester the “default harness” for concurrent OTP tests across your repos**:
> predictable, debuggable, high-signal tests that happily run `async: true` by default.

### Secondary goals

* **Keep current public API working** where reasonable (0.2.x line).
* Prepare a **cleaner, more orthogonal 1.0 API** if/when you choose to cut one.
* Bring **implementation and docs into tight alignment** (design docs vs reality).
* Make the library **less ExUnit-hardcoded**, more “harness” and less “just helpers”.

I’ll lean hard toward concurrency/isolation, and fold chaos/perf into that harness rather than as separate islands.

---

## Phase 1 – Core Isolation & Concurrency Harness Hardening

Focus: make the foundations absolutely solid for concurrent testing.

### 1.1. Fix & simplify `UnifiedTestFoundation.__using__/1`

**Problem today**

* `UnifiedTestFoundation.__using__` calls `use ExUnit.Case` internally and decides `async: true/false` there.
* Docs also show `use ExUnit.Case` in user test modules → risk of double use / confusion.
* Tightly couples Supertester to ExUnit macros instead of acting as a composable layer.

**Plan**

1. **Split responsibilities into two modules:**

   * `Supertester.UnifiedTestFoundation` – **pure isolation runtime**:

     * no `use ExUnit.Case` inside.
     * only exposes functions like `setup_isolation/2`, `wait_for_supervision_tree_ready/2`.
   * `Supertester.ExUnitFoundation` – **thin adapter**:

     ```elixir
     defmodule Supertester.ExUnitFoundation do
       defmacro __using__(opts) do
         isolation = Keyword.get(opts, :isolation, :full_isolation)

         quote do
           use ExUnit.Case, async: Supertester.UnifiedTestFoundation.isolation_allows_async?(unquote(isolation))

           setup context do
             Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)
           end
         end
       end
     end
     ```

2. **Deprecate current `use Supertester.UnifiedTestFoundation` macro**:

   * Keep it working in 0.2.x by delegating to the new adapter.
   * Emit a compile-time warning:

     > “Supertester.UnifiedTestFoundation now only manages isolation. For ExUnit integration, use Supertester.ExUnitFoundation.”

3. **Align docs** everywhere:

   * Change examples in API_GUIDE, MANUAL, QUICK_START, README to:

     ```elixir
     defmodule MyApp.MyTest do
       use Supertester.ExUnitFoundation, isolation: :full_isolation
       # no direct `use ExUnit.Case` here
     end
     ```

**Acceptance criteria**

* All existing tests compile and pass untouched.
* User can now choose:

  * ExUnit-coupled usage: `use Supertester.ExUnitFoundation`
  * Or call `setup_isolation/2` manually in custom harnesses.
* No docs show `use ExUnit.Case` + `use Supertester.UnifiedTestFoundation` in the same module.

---

### 1.2. Decouple ExUnit from helpers where possible

**Problem today**

* `OTPHelpers.cleanup_on_exit/1` and `UnifiedTestFoundation` both call `ExUnit.Callbacks.on_exit/1` directly.
* This makes helpers awkward to use in non-ExUnit contexts (multi-repo harnesses, custom runners).

**Plan**

1. **Introduce a small environment abstraction**, e.g. `Supertester.Env`:

   ```elixir
   defmodule Supertester.Env do
     @callback on_exit((-> any())) :: :ok

     # Default ExUnit implementation
     def on_exit(fun) do
       apply(ExUnit.Callbacks, :on_exit, [fun])
     end
   end
   ```

2. In `OTPHelpers.cleanup_on_exit/1` and `UnifiedTestFoundation`, call `Supertester.Env.on_exit/1` instead of `ExUnit.Callbacks.on_exit`.

3. Provide a **configuration hook**:

   ```elixir
   # config/test.exs
   config :supertester, env_module: Supertester.Env

   # In custom harnesses, user can plug their own env module.
   ```

**Acceptance criteria**

* All tests still pass using ExUnit.
* You can later drop Supertester into a custom runner by implementing a minimal Env behaviour and configuring it.
* No direct `ExUnit.Callbacks` calls remain outside adapter modules.

---

### 1.3. Normalize isolation context & metadata

Right now, isolation context is stored in process dictionary under `:isolation_context` with ad-hoc structure.

**Plan**

1. **Define a clear struct**:

   ```elixir
   defmodule Supertester.IsolationContext do
     @type t :: %__MODULE__{
       test_id: term(),
       registry: atom() | nil,
       processes: [%{pid: pid(), name: atom() | nil, module: module()}],
       ets_tables: [ets_table()],
       tags: map()
     }
     defstruct [:test_id, :registry, processes: [], ets_tables: [], tags: %{}]
   end
   ```

2. **Refactor `UnifiedTestFoundation.setup_*` and `OTPHelpers.setup_isolated_*`** to:

   * Always create/update an `IsolationContext` struct.
   * Stop storing free-form maps.

3. **Add helper accessors**:

   ```elixir
   def fetch_isolation_context(), do: Process.get(:isolation_context)
   def put_isolation_context(ctx), do: Process.put(:isolation_context, ctx)
   ```

4. Use this context to attach **metadata for diagnostics**, e.g.:

   * original test name
   * timestamp
   * isolation mode
   * list of tracked resources

**Acceptance criteria**

* All code paths that read/write `:isolation_context` now handle a struct.
* Tests still pass.
* Easy to log “what did this test create?” from `IsolationContext` when debugging.

---

### 1.4. Make core helpers more predictable under concurrency

Focus on `OTPHelpers` and `GenServerHelpers` as the main harness entry points.

#### 1.4.1. Harden `setup_isolated_genserver/3` and `setup_isolated_supervisor/3`

**Tasks**

* Ensure **name derivation** is:

  * deterministic based on `test_id`, module, optional `logical_name`.
  * overrideable via `opts[:name]` if user wants explicit names.
  * documented as: “we guarantee uniqueness within a VM, but not semantic meaning”.

* Add **consistent on-exit cleanup**:

  * For supervisors: stop children before stopping supervisor (avoid race with isolation cleanup).
  * For GenServers: call `GenServer.stop/3`, then fallback to `Process.exit/2` with `:kill` if needed.

* Add **more helpful error messages** when start fails:

  * include module, test name, and init args in error tuples.

**Acceptance criteria**

* Concurrency: you can call `setup_isolated_genserver(MyServer)` from many tests running `async: true` without name collisions.
* Cleanup: after each test, no extra worker processes remain (monitored by `assert_no_process_leaks/1` internally for library self-tests).

#### 1.4.2. Tighten `cast_and_sync/3`

Today, `cast_and_sync/3` assumes a `__supertester_sync__` handler and returns `{:ok, resp} | :ok`.

**Tasks**

* **Explicitly document** the contract:

  * Works best with `use Supertester.TestableGenServer`.
  * If server doesn’t support sync message, error should be explicit, not swallowed.

* **Change behavior non-breakingly:**

  * Today you swallow `{:error, :unknown_call}` as “probably okay”.

  * Instead, expose a `:strict` option:

    ```elixir
    cast_and_sync(server, msg, sync_msg \\ :__supertester_sync__, opts \\ [])

    # opts:
    #   strict?: true | false  (default: false to remain compatible)
    ```

  * In strict mode, raise when sync handler missing; in non-strict mode, keep existing behavior but log debug.

**Acceptance criteria**

* Backwards compatible by default.
* Users get a way to force “sync message must exist” to catch misconfigured servers.

#### 1.4.3. Make `concurrent_calls/3` and `stress_test_server/3` harness primitives

Right now they exist, but they’re fairly free-form. For concurrency harness, we want them to act as **building blocks**.

**Tasks**

* For `concurrent_calls/3`:

  * Add **per-call timeout** argument or option.
  * Include **metadata** in results:

    ```elixir
    {:ok, [%{call: term(), successes: [term()], errors: [term()]}]}
    ```

    (instead of `{call, [term()]}` tuples).
  * Ensure tasks are supervised with clear timeouts and failure behavior (no lingering tasks).

* For `stress_test_server/3`:

  * Return a well-typed struct: `%{calls: non_neg_integer, casts: non_neg_integer, errors: non_neg_integer, duration_ms: non_neg_integer}`.
  * Make the number of worker processes configurable.
  * Use `receive ... after` correctly with remaining timeout (you already do this elsewhere; match pattern).

**Acceptance criteria**

* Concurrent GenServer harness utilities have stable, documented result shapes usable by higher-level API (Phase 2).
* They don’t leak tasks or processes under error conditions.

---

## Phase 2 – Concurrency-First Harness Layer

Now we build a proper “scenario harness” on top of the strengthened core.

### 2.1. Introduce `Supertester.ConcurrentHarness`

**Goal**

Provide a high-level API that lets you describe concurrent scenarios, run them, and attach invariants.

**API sketch**

```elixir
defmodule Supertester.ConcurrentHarness do
  @type operation :: {:call, term()} | {:cast, term()} | {:custom, (pid() -> any())}
  @type thread_script :: [operation()]
  @type scenario :: %{
    setup: (-> {:ok, pid()} | {:ok, pid(), map()}),
    threads: [thread_script()],
    timeout_ms: pos_integer(),
    invariant: (pid(), map() -> boolean() | no_return),
    cleanup: (pid(), map() -> any()) | nil
  }

  @spec run(scenario()) :: {:ok, %{events: [term()], metrics: map()}} | {:error, term()}
end
```

**Tasks**

1. Implement `ConcurrentHarness.run/1`:

   * Call `scenario.setup/0` to obtain the primary process (often a GenServer under test).
   * Spawn N worker tasks, each executing its `thread_script` against that process.
   * Coordinate them with:

     * `call_with_timeout/3` for calls.
     * `cast_and_sync/3` for casts (by default, or allow `no_sync: true`).
   * Record events: start time, each op, result, final state (if `TestableGenServer`).
   * After all threads complete (or timeout), run `scenario.invariant/2`.
   * Ensure `scenario.cleanup/2` is called in `after` clause.

2. Add **helpers to build scenarios** quickly (thin wrappers):

   ```elixir
   def simple_genserver_scenario(module, ops_per_thread, n_threads, opts \\ [])
   ```

3. Integrate with `PropertyHelpers` once available (see 2.2).

**Acceptance criteria**

* You can write tests like:

  ```elixir
  test "counter invariants under concurrency" do
    scenario = Supertester.ConcurrentHarness.simple_genserver_scenario(
      Counter,
      [:increment, :decrement],
      10,
      invariant: fn server, _ctx ->
        {:ok, state} = get_server_state_safely(server)
        assert state.count >= 0
      end
    )

    assert {:ok, _report} = Supertester.ConcurrentHarness.run(scenario)
  end
  ```

* Harness takes care of launching, synchronizing, and collecting metrics.

---

### 2.2. Implement `PropertyHelpers` focused on concurrency

You already have a detailed technical design doc; let’s align it with the harness.

**Tasks**

1. Add `Supertester.PropertyHelpers` with:

   * `genserver_operation_sequence/2`
   * `concurrent_scenario/1`

   but ensure they output structures directly consumable by `ConcurrentHarness.run/1`.

   Example:

   ```elixir
   property "concurrent invariants hold" do
     check all scenario_cfg <- concurrent_scenario(...) do
       scenario = ConcurrentHarness.from_property_config(Counter, scenario_cfg)
       assert {:ok, _} = ConcurrentHarness.run(scenario)
     end
   end
   ```

2. Integrate `StreamData` only when available (already optional dep):

   * If `:stream_data` not present, property helpers raise with clear message suggesting `{:stream_data, "~> 1.0", only: :test}`.

3. Add a **meta-test** that uses PropertyHelpers to test one of your own helper modules (e.g., `GenServerHelpers`) to validate harness usefulness.

**Acceptance criteria**

* PropertyHelpers is actually implemented (not just in docs).
* At least one real property test for a sample GenServer included in `test/`.
* Property-based concurrency tests integrate cleanly with `ConcurrentHarness`.

---

### 2.3. Message and mailbox visibility utilities

Even without a full `MessageHelpers` module, you can give users better observability.

**Tasks**

1. Add a minimal `Supertester.MessageHarness` (or fold into `ConcurrentHarness`) with:

   * `trace_messages(pid, fun, opts \\ []) :: %{messages: [term()], result: term()}`

     * Wraps a function execution and records messages received by target pid.
     * Uses `Process.info(pid, :messages)` before/after, plus optional hooking.

2. Improve `PerformanceHelpers.measure_mailbox_growth/2`:

   * Allow a configurable sampling interval.
   * Provide integration with `ConcurrentHarness`:

     * e.g. `ConcurrentHarness.run/1` optionally returns mailbox stats if asked.

**Acceptance criteria**

* You can write a test that says: “Run this concurrent scenario and assert that mailbox max size never exceeds X”.
* Foundation for a richer `MessageHelpers` module is in place but does not block core harness usage.

---

## Phase 3 – Resilience & Performance as First-Class Concerns

Focus: make chaos and performance integrate into the harness instead of being standalone helpers.

### 3.1. Integrate Chaos into ConcurrentHarness

**Tasks**

1. Extend `ConcurrentHarness` scenarios with optional `chaos` hook:

   ```elixir
   %{
     setup: ...,
     threads: ...,
     chaos: (pid(), map() -> any()) | nil,
     invariant: ...,
     ...
   }
   ```

2. Provide canned chaos hooks built from `ChaosHelpers`:

   * `chaos_kill_children(supervisor, opts)` as a ready-made chaos step.
   * `simulate_resource_exhaustion/2` wrappers that are easy to call inside the `chaos` phase.

3. Make `ChaosHelpers.run_chaos_suite/3` use ConcurrentHarness internally when appropriate, so semantics are uniform.

**Acceptance criteria**

* You can write: “run this concurrent scenario *and while it runs*, inject chaos X” in one test.
* Chaos modules no longer feel like a separate subsystem; they plug into the same harness.

---

### 3.2. Make performance assertions harness-aware

**Tasks**

1. Add an option to `ConcurrentHarness.run/1`:

   ```elixir
   scenario = %{..., performance_expectations: [max_time_ms: 100, max_memory_bytes: 1_000_000]}
   ```

   and internally call `PerformanceHelpers.assert_performance/2` around the scenario execution.

2. Add a high-level helper:

   ```elixir
   def run_with_performance(scenario, expectations),
       do: assert_performance(fn -> run(scenario) end, expectations)
   ```

3. Slightly refine `PerformanceHelpers.assert_no_memory_leak/3`:

   * Accept an optional label / metadata (for better error messages).
   * Use the same sample points your design doc describes, but log normalized percentages.

**Acceptance criteria**

* Single entry point to say: “run this concurrent scenario, and fail if it takes longer than X or leaks memory.”
* You don’t need to manually wrap harness calls in performance helpers in tests (though you still can).

---

## Phase 4 – Distributed & System-Level Concurrency

You already have a design for `DistributedHelpers`; here’s how to scope it so it plays nicely with the harness but doesn’t block 1.0.

### 4.1. `DistributedHelpers` minimal but composable

**Tasks**

1. Implement `setup_test_cluster/1` with a **small but stable contract**:

   ```elixir
   @type cluster_info :: %{nodes: [node()], cleanup: (() -> :ok)}

   @spec setup_test_cluster(keyword()) :: {:ok, cluster_info} | {:error, term()}
   ```

2. Add a helper to run `ConcurrentHarness` against a node:

   ```elixir
   def run_on_node(node, scenario) do
     :rpc.call(node, Supertester.ConcurrentHarness, :run, [scenario])
   end
   ```

3. Provide 1–2 canonical examples in tests:

   * Distributed cache that must converge.
   * Simple partition & heal scenario.

**Acceptance criteria**

* Distributed helpers exist but are thin wrappers around harness + `:rpc`.
* The harness API does not need to understand clustering; it just runs scenarios on a node.

---

## Phase 5 – API Refinement & Optional Breaking Changes

Once phases 1–4 are stable, you can decide whether to cut a **1.0** with a slightly cleaned-up API. Here’s what I’d bake into that.

### 5.1. Namespace cleanup

**Possible changes (behind deprecations first)**

* Move “adapter” modules into a clear namespace:

  * `Supertester.ExUnitFoundation`
  * Later: `Supertester.LivebookIntegration`, etc.

* Keep “pure” modules in root namespace:

  * `Supertester.{OTPHelpers, GenServerHelpers, SupervisorHelpers, ChaosHelpers, PerformanceHelpers, ConcurrentHarness, PropertyHelpers}`.

### 5.2. Type & return-shape normalization

Aim for:

* Helper functions returning **structs** instead of raw maps when results are complex (`chaos_suite_report`, performance metrics, etc.).
* Consistent error return convention (`{:error, reason}`) instead of mixed raising vs returning in similar contexts.

You can introduce these as **new functions** initially:

* `run_chaos_suite/3` → `run_chaos_suite!/3` that raises on failure.
* Keep older versions for 0.2.x, deprecate in 1.0.

### 5.3. Test macros / DSL

If you want to go further, add a very light DSL that wraps common patterns:

```elixir
use Supertester.TestCase, isolation: :full_isolation

concurrent_test "counter is monotonic" do
  using Counter
  threads 10, ops: [:increment, :decrement]
  invariant fn state -> state.count >= 0 end
end
```

This is optional but could greatly improve ergonomics in your 6-repo monorepo context.

---

## Cross-Cutting Tasks (All Phases)

These should be done incrementally alongside the phases.

### A. Test suite enhancements

* Add **library self-tests** that exercise:

  * Isolation context behavior under many async tests.
  * `ConcurrentHarness` with a few realistic GenServers.
  * Property-based concurrency tests (once PropertyHelpers exist).
  * At least one distributed scenario, if you add DistributedHelpers.

* Use `assert_no_process_leaks/1` and `assert_memory_usage_stable/2` to validate Supertester itself under its own patterns (meta-tests).

### B. Telemetry & diagnostics

* Introduce a `Supertester.Telemetry` module:

  * Wrap emissions for:

    * `[:supertester, :concurrent, :scenario_start/stop]`
    * `[:supertester, :chaos, :injected]`
    * `[:supertester, :performance, :measured]`

* All high-level APIs (ConcurrentHarness, ChaosHelpers, PerformanceHelpers) should emit events using this single module.

### C. Documentation & alignment

* Update docs after each phase:

  * Make sure docs don’t reference modules that don’t yet exist (`DataGenerators`, full `MessageHelpers`, etc.), or clearly mark them as “planned”.
  * Keep API_GUIDE and MANUAL as the **single source of truth** for publicly supported functions.

* Add **“migration from 0.2.x to 1.0”** page once you decide on any breaking changes.

---

## Suggested Execution Order

For a concrete agent:

1. **Phase 1 (Core hardening)** – absolutely first.

   * 1.1, 1.2, 1.3, 1.4 in that order.
2. **Phase 2 (ConcurrentHarness + PropertyHelpers)** – second.

   * Build harness, then property, then message/mailbox visibility.
3. **Phase 3 (Integrate chaos & perf into harness)**.
4. **Phase 4 (Distributed helpers)** – only if you actually need multi-node in your 6 repos right now.
5. **Phase 5 (API & ergonomics)** – only when you’re comfortable planning a 1.0.

If you want *one sentence* priority statement:

> **Do Phase 1 + Phase 2.1 (ConcurrentHarness) first; everything else can layer on later.**

That gives you a solid, composable concurrent-testing harness you can roll out across your projects while keeping existing helpers and tests working as-is.
