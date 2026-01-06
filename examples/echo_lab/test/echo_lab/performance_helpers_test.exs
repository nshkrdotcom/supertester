defmodule EchoLab.PerformanceHelpersTest do
  use ExUnit.Case, async: true

  import Supertester.PerformanceHelpers

  test "measure_operation and assert_expectations" do
    measurement = measure_operation(fn -> Enum.sum(1..10) end)

    assert measurement.time_us >= 0
    assert measurement.memory_bytes >= 0
    assert measurement.reductions >= 0
    assert measurement.result == 55

    assert_expectations(measurement, max_time_ms: 100, max_memory_bytes: 10_000_000)
  end

  test "assert_performance enforces expectations" do
    assert_performance(fn -> Enum.sum(1..100) end, max_time_ms: 500)
  end

  test "mailbox monitoring helpers" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    report =
      measure_mailbox_growth(pid, fn ->
        Enum.each(1..5, fn _ -> send(pid, :ping) end)
        :ok
      end)

    assert report.max_size >= report.initial_size

    stable_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert_mailbox_stable(stable_pid,
      during: fn -> send(stable_pid, :stable) end,
      max_size: 10
    )

    send(pid, :stop)
    send(stable_pid, :stop)
  end

  test "compare_performance and assert_no_memory_leak" do
    results =
      compare_performance(%{
        one: fn -> Enum.sum(1..5) end,
        two: fn -> Enum.sum(1..10) end
      })

    assert Map.has_key?(results, :one)
    assert Map.has_key?(results, :two)

    assert_no_memory_leak(20, fn -> Enum.sum(1..10) end)
  end
end
