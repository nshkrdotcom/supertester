defmodule Supertester.TelemetryHelpersTest do
  use ExUnit.Case, async: true

  alias Supertester.TelemetryHelpers

  import Supertester.TelemetryHelpers,
    only: [
      assert_telemetry: 1,
      assert_telemetry: 2,
      refute_telemetry: 2
    ]

  describe "setup_telemetry_isolation/0" do
    test "stores test id in the process dictionary" do
      {:ok, test_id} = TelemetryHelpers.setup_telemetry_isolation()

      assert is_integer(test_id)
      assert TelemetryHelpers.get_test_id() == test_id
    end
  end

  describe "test id accessors" do
    test "get_test_id/0 returns nil when unset" do
      Process.delete(:supertester_telemetry_test_id)
      assert TelemetryHelpers.get_test_id() == nil
    end

    test "get_test_id!/0 raises when unset" do
      Process.delete(:supertester_telemetry_test_id)

      assert_raise RuntimeError, ~r/Telemetry isolation not set up/, fn ->
        TelemetryHelpers.get_test_id!()
      end
    end
  end

  describe "current_test_metadata/0" do
    test "returns empty map when unset" do
      Process.delete(:supertester_telemetry_test_id)
      assert TelemetryHelpers.current_test_metadata() == %{}
    end

    test "merges test metadata into map" do
      {:ok, test_id} = TelemetryHelpers.setup_telemetry_isolation()

      assert TelemetryHelpers.current_test_metadata() == %{supertester_test_id: test_id}

      merged = TelemetryHelpers.current_test_metadata(%{key: :value})
      assert merged == %{key: :value, supertester_test_id: test_id}
    end
  end

  describe "attach_isolated/2" do
    setup do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      :ok
    end

    test "only delivers events with matching test id" do
      {:ok, _} = TelemetryHelpers.attach_isolated([:test, :event])

      TelemetryHelpers.emit_with_context([:test, :event], %{value: 1}, %{source: "correct"})
      :telemetry.execute([:test, :event], %{value: 2}, %{source: "wrong"})

      assert_receive {:telemetry, [:test, :event], %{value: 1}, %{source: "correct"}}
      refute_receive {:telemetry, [:test, :event], %{value: 2}, _}, 50
    end

    test "passthrough delivers events without test id" do
      {:ok, _} = TelemetryHelpers.attach_isolated([:test, :event], passthrough: true)

      :telemetry.execute([:test, :event], %{value: 1}, %{source: "no_id"})

      assert_receive {:telemetry, [:test, :event], %{value: 1}, %{source: "no_id"}}
    end

    test "transform option rewrites delivered messages" do
      {:ok, _} =
        TelemetryHelpers.attach_isolated([:test, :event],
          transform: fn message -> {:wrapped, message} end
        )

      TelemetryHelpers.emit_with_context([:test, :event], %{value: 3}, %{source: "wrapped"})

      assert_receive {:wrapped, {:telemetry, [:test, :event], %{value: 3}, %{source: "wrapped"}}}
    end
  end

  describe "assertion macros" do
    setup do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _} = TelemetryHelpers.attach_isolated([[:test, :success], [:test, :meta]])
      :ok
    end

    test "assert_telemetry/1 matches by event" do
      TelemetryHelpers.emit_with_context([:test, :success], %{}, %{key: "value"})

      msg = assert_telemetry([:test, :success])
      assert {:telemetry, [:test, :success], %{}, %{key: "value"}} = msg
    end

    test "assert_telemetry/2 matches event and metadata" do
      TelemetryHelpers.emit_with_context([:test, :meta], %{}, %{id: 1, other: "ignore"})

      msg = assert_telemetry([:test, :meta], %{id: 1})
      assert {:telemetry, [:test, :meta], %{}, %{id: 1}} = msg
    end

    test "assert_telemetry/2 raises when missing" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_telemetry([:test, :missing], timeout: 50)
      end
    end

    test "refute_telemetry/2 raises when matching event received" do
      TelemetryHelpers.emit_with_context([:test, :success], %{}, %{key: "value"})

      assert_raise ExUnit.AssertionError, fn ->
        refute_telemetry([:test, :success], timeout: 50)
      end
    end

    test "refute_telemetry/2 succeeds when no matching event" do
      refute_telemetry([:test, :success], timeout: 20)
    end
  end

  describe "counting and flushing" do
    setup do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      {:ok, _} = TelemetryHelpers.attach_isolated([[:test, :count], [:test, :flush]])
      :ok
    end

    test "assert_telemetry_count/2 returns expected events" do
      TelemetryHelpers.emit_with_context([:test, :count], %{}, %{attempt: 1})
      TelemetryHelpers.emit_with_context([:test, :count], %{}, %{attempt: 2})

      events = TelemetryHelpers.assert_telemetry_count([:test, :count], 2)

      assert Enum.map(events, fn {:telemetry, _, _, %{attempt: n}} -> n end) == [1, 2]
    end

    test "flush_telemetry/1 removes telemetry messages" do
      TelemetryHelpers.emit_with_context([:test, :flush], %{}, %{id: 1})
      TelemetryHelpers.emit_with_context([:test, :flush], %{}, %{id: 2})

      events = TelemetryHelpers.flush_telemetry(:all)
      assert length(events) == 2

      refute_receive {:telemetry, _, _, _}, 0
    end
  end

  describe "with_telemetry/3 and emit_with_context/3" do
    setup do
      {:ok, _} = TelemetryHelpers.setup_telemetry_isolation()
      :ok
    end

    test "with_telemetry/3 captures buffered events" do
      {result, events} =
        TelemetryHelpers.with_telemetry([[:test, :buffered]], fn ->
          TelemetryHelpers.emit_with_context([:test, :buffered], %{value: 1}, %{})
          :ok
        end)

      assert result == :ok
      assert [{:telemetry, [:test, :buffered], %{value: 1}, _}] = events
    end

    test "emit_with_context/3 injects the test id" do
      {:ok, _} = TelemetryHelpers.attach_isolated([:test, :context])

      test_id = TelemetryHelpers.get_test_id!()
      TelemetryHelpers.emit_with_context([:test, :context], %{}, %{tag: "ok"})

      assert_receive {:telemetry, [:test, :context], %{},
                      %{supertester_test_id: ^test_id, tag: "ok"}}
    end
  end
end
