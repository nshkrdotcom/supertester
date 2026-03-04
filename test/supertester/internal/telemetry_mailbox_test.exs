defmodule Supertester.Internal.TelemetryMailboxTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.TelemetryMailbox

  setup do
    TelemetryMailbox.flush_all()

    on_exit(fn ->
      TelemetryMailbox.flush_all()
    end)

    :ok
  end

  test "flush_matching/2 drains only matching events and preserves unmatched telemetry" do
    msg_a = {:telemetry, [:mailbox, :a], %{}, %{supertester_test_id: 1}}
    msg_b = {:telemetry, [:mailbox, :b], %{}, %{supertester_test_id: 1}}

    send(self(), msg_a)
    send(self(), msg_b)

    assert [^msg_a] = TelemetryMailbox.flush_matching([:mailbox, :a], 1)
    assert_receive ^msg_b
  end

  test "flush_matching_many/2 matches multiple events while preserving unrelated messages" do
    match_a = {:telemetry, [:mailbox, :a], %{}, %{supertester_test_id: 11}}
    match_b = {:telemetry, [:mailbox, :b], %{}, %{supertester_test_id: 11}}
    wrong_test = {:telemetry, [:mailbox, :a], %{}, %{supertester_test_id: 22}}
    non_match = {:telemetry, [:mailbox, :c], %{}, %{supertester_test_id: 11}}

    send(self(), match_a)
    send(self(), wrong_test)
    send(self(), non_match)
    send(self(), match_b)

    assert [^match_a, ^match_b] =
             TelemetryMailbox.flush_matching_many([[:mailbox, :a], [:mailbox, :b]], 11)

    assert_receive ^wrong_test
    assert_receive ^non_match
  end

  test "receive_matching/4 requeues skipped telemetry messages in order" do
    first = {:telemetry, [:mailbox, :skip], %{}, %{supertester_test_id: 50}}
    wanted = {:telemetry, [:mailbox, :wanted], %{}, %{supertester_test_id: 50}}
    third = {:telemetry, [:mailbox, :skip_after], %{}, %{supertester_test_id: 50}}

    send(self(), first)
    send(self(), wanted)
    send(self(), third)

    assert {:ok, ^wanted} = TelemetryMailbox.receive_matching([:mailbox, :wanted], nil, 50, 100)

    assert_receive ^first
    assert_receive ^third
  end
end
