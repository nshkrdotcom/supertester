defmodule Supertester.TelemetryHelpers do
  @moduledoc """
  Async-safe telemetry testing helpers with per-test event isolation.
  """

  alias Supertester.{Env, IsolationContext, Telemetry, UnifiedTestFoundation}

  @type event :: [atom()]
  @type measurements :: map()
  @type metadata :: map()
  @type handler_id :: String.t()
  @type test_id :: integer()
  @type telemetry_message :: {:telemetry, event(), measurements(), metadata()}

  @type attach_opts :: [
          filter_key: atom(),
          passthrough: boolean(),
          buffer: boolean(),
          transform: (telemetry_message() -> term())
        ]

  @type assert_opts :: [
          timeout: pos_integer()
        ]

  @doc """
  Initialize telemetry isolation for the current process.
  """
  @spec setup_telemetry_isolation() :: {:ok, test_id()}
  def setup_telemetry_isolation do
    test_id = System.unique_integer([:positive, :monotonic])
    Process.put(:supertester_telemetry_test_id, test_id)
    maybe_update_context(fn ctx -> %{ctx | telemetry_test_id: test_id} end)
    {:ok, test_id}
  end

  @doc """
  Initialize telemetry isolation and update the isolation context.
  """
  @spec setup_telemetry_isolation(IsolationContext.t()) ::
          {:ok, test_id(), IsolationContext.t()}
  def setup_telemetry_isolation(%IsolationContext{} = ctx) do
    {:ok, test_id} = setup_telemetry_isolation()
    updated_ctx = %{ctx | telemetry_test_id: test_id}
    UnifiedTestFoundation.put_isolation_context(updated_ctx)
    {:ok, test_id, updated_ctx}
  end

  @doc """
  Attach a telemetry handler that only receives events matching the current test ID.
  """
  @spec attach_isolated(event() | [event()], attach_opts()) :: {:ok, handler_id()}
  def attach_isolated(events, opts \\ []) do
    events = normalize_events(events)
    test_id = get_test_id!()
    handler_id = "supertester-telemetry-#{test_id}-#{System.unique_integer([:positive])}"
    parent = self()

    filter_key = Keyword.get(opts, :filter_key, :supertester_test_id)
    passthrough = Keyword.get(opts, :passthrough, false)
    buffer = Keyword.get(opts, :buffer, false)
    transform = Keyword.get(opts, :transform, &Function.identity/1)

    # Pass context via config to avoid local function warning from telemetry
    handler_config = %{
      test_id: test_id,
      parent: parent,
      filter_key: filter_key,
      passthrough: passthrough,
      buffer: buffer,
      transform: transform
    }

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        handler_config
      )

    Env.on_exit(fn ->
      :telemetry.detach(handler_id)
      emit_detached(handler_id)
    end)

    track_handler(handler_id, events)
    emit_attached(handler_id, events, test_id)
    {:ok, handler_id}
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, config) do
    %{
      test_id: test_id,
      parent: parent,
      filter_key: filter_key,
      passthrough: passthrough,
      buffer: buffer,
      transform: transform
    } = config

    event_test_id = Map.get(metadata, filter_key)

    should_deliver =
      event_test_id == test_id or
        (passthrough and is_nil(event_test_id))

    if should_deliver do
      message = transform.({:telemetry, event, measurements, metadata})
      deliver_event(parent, message, buffer)
      emit_delivered(event, test_id)
    else
      emit_filtered(event, event_test_id, test_id)
    end
  end

  @doc """
  Retrieve the current test's telemetry ID.
  """
  @spec get_test_id() :: test_id() | nil
  def get_test_id do
    Process.get(:supertester_telemetry_test_id)
  end

  @doc """
  Retrieve the current test's telemetry ID or raise if missing.
  """
  @spec get_test_id!() :: test_id()
  def get_test_id! do
    case get_test_id() do
      nil ->
        raise "Telemetry isolation not set up. Call setup_telemetry_isolation/0 first."

      id ->
        id
    end
  end

  @doc """
  Return metadata map containing the current test's telemetry ID.
  """
  @spec current_test_metadata() :: map()
  def current_test_metadata do
    case get_test_id() do
      nil -> %{}
      id -> %{supertester_test_id: id}
    end
  end

  @doc """
  Merge the current test's telemetry metadata into an existing map.
  """
  @spec current_test_metadata(map()) :: map()
  def current_test_metadata(existing) when is_map(existing) do
    Map.merge(existing, current_test_metadata())
  end

  @doc false
  defmacro assert_telemetry(event_pattern) do
    quote do
      Supertester.TelemetryHelpers.__assert_telemetry__(unquote(event_pattern), nil, [])
    end
  end

  @doc false
  defmacro assert_telemetry(event_pattern, metadata_or_opts) do
    quote do
      Supertester.TelemetryHelpers.__assert_telemetry__(
        unquote(event_pattern),
        unquote(metadata_or_opts),
        []
      )
    end
  end

  @doc false
  defmacro assert_telemetry(event_pattern, metadata_pattern, opts) do
    quote do
      Supertester.TelemetryHelpers.__assert_telemetry__(
        unquote(event_pattern),
        unquote(metadata_pattern),
        unquote(opts)
      )
    end
  end

  @doc false
  @spec __assert_telemetry__(
          event() | (event() -> boolean()),
          map() | (map() -> boolean()) | nil,
          assert_opts()
        ) ::
          telemetry_message()
  def __assert_telemetry__(event_pattern, metadata_or_opts, opts) do
    {metadata_pattern, opts} = normalize_assert_args(metadata_or_opts, opts)
    timeout = Keyword.get(opts, :timeout, 1000)
    test_id = get_test_id!()

    case receive_matching_telemetry(event_pattern, metadata_pattern, test_id, timeout) do
      {:ok, msg} ->
        msg

      :timeout ->
        raise ExUnit.AssertionError,
          message: build_assert_message(event_pattern, metadata_pattern, test_id, timeout)
    end
  end

  @doc false
  defmacro refute_telemetry(event_pattern) do
    quote do
      Supertester.TelemetryHelpers.__refute_telemetry__(unquote(event_pattern), [])
    end
  end

  @doc false
  defmacro refute_telemetry(event_pattern, opts) do
    quote do
      Supertester.TelemetryHelpers.__refute_telemetry__(unquote(event_pattern), unquote(opts))
    end
  end

  @doc false
  @spec __refute_telemetry__(event() | (event() -> boolean()), assert_opts()) :: :ok
  def __refute_telemetry__(event_pattern, opts) do
    timeout = Keyword.get(opts, :timeout, 100)
    test_id = get_test_id!()

    case receive_matching_telemetry(event_pattern, nil, test_id, timeout) do
      {:ok, msg} ->
        raise ExUnit.AssertionError,
          message:
            "Expected NO telemetry event matching #{inspect(event_pattern)}, but received: #{inspect(msg)}"

      :timeout ->
        :ok
    end
  end

  @doc """
  Assert exactly `expected_count` telemetry events were received.
  """
  @spec assert_telemetry_count(event() | (event() -> boolean()), pos_integer(), assert_opts()) ::
          [telemetry_message()]
  def assert_telemetry_count(event_pattern, expected_count, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    test_id = get_test_id!()

    events = collect_telemetry_events(event_pattern, test_id, expected_count, timeout)
    actual_count = length(events)

    if actual_count != expected_count do
      raise ExUnit.AssertionError,
        message:
          "Expected #{expected_count} telemetry events matching #{inspect(event_pattern)}, " <>
            "but received #{actual_count}"
    end

    events
  end

  @doc """
  Flush telemetry messages from the mailbox.
  """
  @spec flush_telemetry(:all | event()) :: [telemetry_message()]
  def flush_telemetry(:all) do
    flush_telemetry_loop([])
  end

  def flush_telemetry(event_pattern) do
    test_id = get_test_id()

    flush_telemetry(:all)
    |> Enum.filter(fn {:telemetry, event, _measurements, metadata} ->
      matches_event?(event, event_pattern) and matches_test_id?(metadata, test_id)
    end)
  end

  @doc """
  Execute a function and capture emitted telemetry events.
  """
  @spec with_telemetry(event() | [event()], (-> result), attach_opts()) ::
          {result, [telemetry_message()]}
        when result: term()
  def with_telemetry(events, fun, opts \\ []) when is_function(fun, 0) do
    {:ok, _handler_id} = attach_isolated(events, Keyword.put(opts, :buffer, true))

    result = fun.()

    receive do
    after
      10 -> :ok
    end

    {result, flush_buffer()}
  end

  @doc """
  Emit a telemetry event with the current test's context.
  """
  @spec emit_with_context(event(), measurements(), metadata()) :: :ok
  def emit_with_context(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, current_test_metadata(metadata))
  end

  defp normalize_events([]), do: []
  defp normalize_events([head | _] = events) when is_list(head), do: events
  defp normalize_events(events), do: [events]

  defp track_handler(handler_id, events) do
    maybe_update_context(fn ctx ->
      %{ctx | telemetry_handlers: [{handler_id, events} | ctx.telemetry_handlers]}
    end)
  end

  defp maybe_update_context(fun) do
    case UnifiedTestFoundation.fetch_isolation_context() do
      %IsolationContext{} = ctx ->
        updated_ctx = fun.(ctx)
        UnifiedTestFoundation.put_isolation_context(updated_ctx)
        updated_ctx

      _ ->
        nil
    end
  end

  defp flush_telemetry_loop(acc) do
    receive do
      {:telemetry, _, _, _} = msg ->
        flush_telemetry_loop([msg | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

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
      nil ->
        []

      pid ->
        events = Agent.get(pid, &Enum.reverse/1)
        Agent.stop(pid)
        events
    end
  end

  defp receive_matching_telemetry(event_pattern, metadata_pattern, test_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_matching(event_pattern, metadata_pattern, test_id, deadline, [])
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

  defp normalize_assert_args(metadata_or_opts, opts) do
    if is_list(metadata_or_opts) and Keyword.keyword?(metadata_or_opts) and opts == [] do
      {nil, metadata_or_opts}
    else
      {metadata_or_opts, opts}
    end
  end

  defp build_assert_message(event_pattern, nil, test_id, timeout) do
    "Expected telemetry event matching #{inspect(event_pattern)} with test_id #{test_id}, " <>
      "but none received within #{timeout}ms"
  end

  defp build_assert_message(event_pattern, metadata_pattern, _test_id, timeout) do
    "Expected telemetry event #{inspect(event_pattern)} with metadata matching " <>
      "#{inspect(metadata_pattern)}, but none received within #{timeout}ms"
  end

  defp collect_telemetry_events(event_pattern, test_id, expected_count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_telemetry_events([], event_pattern, test_id, expected_count, deadline)
  end

  defp do_collect_telemetry_events(acc, _event_pattern, _test_id, expected_count, _deadline)
       when length(acc) >= expected_count do
    Enum.reverse(acc)
  end

  defp do_collect_telemetry_events(acc, event_pattern, test_id, expected_count, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case receive_matching_telemetry(event_pattern, nil, test_id, remaining) do
        {:ok, msg} ->
          do_collect_telemetry_events(
            [msg | acc],
            event_pattern,
            test_id,
            expected_count,
            deadline
          )

        :timeout ->
          Enum.reverse(acc)
      end
    end
  end

  defp emit_attached(handler_id, events, test_id) do
    Telemetry.emit([:telemetry, :handler, :attached], %{}, %{
      handler_id: handler_id,
      events: events,
      test_id: test_id
    })
  end

  defp emit_detached(handler_id) do
    Telemetry.emit([:telemetry, :handler, :detached], %{}, %{handler_id: handler_id})
  end

  defp emit_filtered(event, event_test_id, handler_test_id) do
    Telemetry.emit([:telemetry, :event, :filtered], %{count: 1}, %{
      event: event,
      event_test_id: event_test_id,
      handler_test_id: handler_test_id
    })
  end

  defp emit_delivered(event, test_id) do
    Telemetry.emit([:telemetry, :event, :delivered], %{count: 1}, %{
      event: event,
      test_id: test_id
    })
  end

  defp deliver_event(parent, message, true), do: buffer_event(parent, message)
  defp deliver_event(parent, message, false), do: send(parent, message)
end
