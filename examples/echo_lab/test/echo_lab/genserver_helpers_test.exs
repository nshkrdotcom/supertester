defmodule EchoLab.GenServerHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.GenServerHelpers

  alias EchoLab.{BareServer, TestableCounter}

  test "get_server_state_safely and call_with_timeout" do
    {:ok, pid} = TestableCounter.start_link(initial: 4)

    assert {:ok, %{count: 4}} = get_server_state_safely(pid)
    assert {:ok, 4} = call_with_timeout(pid, :value, 1_000)
  end

  test "cast_and_sync with TestableGenServer" do
    {:ok, pid} = TestableCounter.start_link(initial: 0)

    assert :ok = cast_and_sync(pid, :increment)
    assert {:ok, 1} = call_with_timeout(pid, :value, 1_000)
  end

  test "cast_and_sync strict mode raises on missing handler" do
    {:ok, pid} = BareServer.start_link()

    assert_raise ArgumentError, fn ->
      cast_and_sync(pid, :ping, :__supertester_sync__, strict?: true)
    end
  end

  test "concurrent_calls aggregates responses" do
    {:ok, pid} = TestableCounter.start_link(initial: 1)

    {:ok, results} = concurrent_calls(pid, [:value, {:add, 2}], 2, timeout: 500)

    assert Enum.any?(results, &match?(%{call: :value}, &1))
    assert Enum.any?(results, &match?(%{call: {:add, 2}}, &1))
  end

  test "stress_test_server returns stats" do
    {:ok, pid} = TestableCounter.start_link(initial: 0)

    operations = [
      {:call, :value},
      {:cast, :increment},
      {:call, {:add, 1}}
    ]

    {:ok, stats} = stress_test_server(pid, operations, 50, workers: 2)

    assert stats.calls + stats.casts >= 1
  end

  test "test_server_crash_recovery reports recovery" do
    registry_name = :"echo_lab_registry_#{System.unique_integer([:positive])}"
    {:ok, registry} = Registry.start_link(keys: :unique, name: registry_name)
    Process.unlink(registry)

    via_name = {:via, Registry, {registry_name, :crash_counter}}

    _sup =
      start_supervised!(%{
        id: :crash_supervisor,
        start:
          {Supervisor, :start_link,
           [
             [Supervisor.child_spec({TestableCounter, name: via_name}, id: :counter)],
             [strategy: :one_for_one]
           ]}
      })

    on_exit(fn ->
      if Process.alive?(registry) do
        try do
          GenServer.stop(registry)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, info} = test_server_crash_recovery(via_name, :crash)
    assert info.recovered == true
  end

  test "test_invalid_messages returns per-message results" do
    {:ok, pid} = BareServer.start_link()

    {:ok, results} = test_invalid_messages(pid, [:unknown, {:bad, 1}])
    assert Enum.any?(results, fn {message, _} -> message == :unknown end)
  end
end
