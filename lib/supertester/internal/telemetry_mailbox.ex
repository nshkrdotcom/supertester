defmodule Supertester.Internal.TelemetryMailbox do
  @moduledoc false

  @type event :: [atom()]
  @type measurements :: map()
  @type metadata :: map()
  @type telemetry_message :: {:telemetry, event(), measurements(), metadata()}

  @spec flush_all() :: [telemetry_message()]
  def flush_all do
    do_flush_all([])
  end

  @spec flush_matching(event(), integer() | nil) :: [telemetry_message()]
  def flush_matching(event_pattern, test_id) do
    matcher = fn event, metadata ->
      matches_event?(event, event_pattern) and matches_test_id?(metadata, test_id)
    end

    do_flush_selecting(matcher, [], [])
  end

  @spec flush_matching_many([event()], integer() | nil) :: [telemetry_message()]
  def flush_matching_many(event_patterns, test_id) when is_list(event_patterns) do
    matcher = fn event, metadata ->
      event in event_patterns and matches_test_id?(metadata, test_id)
    end

    do_flush_selecting(matcher, [], [])
  end

  @spec receive_matching(
          event() | (event() -> boolean()),
          map() | (map() -> boolean()) | nil,
          integer() | nil,
          non_neg_integer()
        ) ::
          {:ok, telemetry_message()} | :timeout
  def receive_matching(event_pattern, metadata_pattern, test_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_matching(event_pattern, metadata_pattern, test_id, deadline, [])
  end

  @spec collect_matching(
          event() | (event() -> boolean()),
          integer() | nil,
          pos_integer(),
          non_neg_integer()
        ) ::
          [telemetry_message()]
  def collect_matching(event_pattern, test_id, expected_count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_matching([], event_pattern, test_id, expected_count, deadline)
  end

  defp do_flush_all(acc) do
    receive do
      {:telemetry, _, _, _} = msg ->
        do_flush_all([msg | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp do_flush_selecting(matcher, matching, stash) when is_function(matcher, 2) do
    receive do
      {:telemetry, event, _measurements, metadata} = msg ->
        if matcher.(event, metadata) do
          do_flush_selecting(matcher, [msg | matching], stash)
        else
          do_flush_selecting(matcher, matching, [msg | stash])
        end
    after
      0 ->
        requeue_messages(stash)
        Enum.reverse(matching)
    end
  end

  defp do_receive_matching(event_pattern, metadata_pattern, test_id, deadline, stash)
       when is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      requeue_messages(stash)
      :timeout
    else
      receive do
        {:telemetry, event, _measurements, metadata} = msg ->
          if matches_event?(event, event_pattern) and
               matches_metadata?(metadata, metadata_pattern) and
               matches_test_id?(metadata, test_id) do
            requeue_messages(stash)
            {:ok, msg}
          else
            do_receive_matching(event_pattern, metadata_pattern, test_id, deadline, [msg | stash])
          end
      after
        remaining ->
          requeue_messages(stash)
          :timeout
      end
    end
  end

  defp do_collect_matching(acc, _event_pattern, _test_id, expected_count, _deadline)
       when length(acc) >= expected_count do
    Enum.reverse(acc)
  end

  defp do_collect_matching(acc, event_pattern, test_id, expected_count, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case receive_matching(event_pattern, nil, test_id, remaining) do
        {:ok, msg} ->
          do_collect_matching([msg | acc], event_pattern, test_id, expected_count, deadline)

        :timeout ->
          Enum.reverse(acc)
      end
    end
  end

  defp requeue_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end

  defp matches_event?(event, pattern) when is_function(pattern, 1), do: pattern.(event)
  defp matches_event?(event, pattern), do: event == pattern

  defp matches_metadata?(_metadata, nil), do: true
  defp matches_metadata?(metadata, pattern) when is_function(pattern, 1), do: pattern.(metadata)

  defp matches_metadata?(metadata, pattern) when is_map(pattern) do
    Enum.all?(pattern, fn {key, value} -> Map.get(metadata, key) == value end)
  end

  defp matches_metadata?(_metadata, _pattern), do: false

  defp matches_test_id?(_metadata, nil), do: true

  defp matches_test_id?(metadata, test_id) do
    Map.get(metadata, :supertester_test_id) == test_id
  end
end
