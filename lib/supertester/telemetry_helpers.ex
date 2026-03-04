defmodule Supertester.TelemetryHelpers do
  @moduledoc """
  Async-safe telemetry testing helpers with per-test event isolation.
  """

  alias Supertester.{Env, IsolationContext, Telemetry}

  alias Supertester.Internal.{
    IsolationContextStore,
    TelemetryBuffer,
    TelemetryHandlerBuffers,
    TelemetryMailbox
  }

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

  @handler_buffers_key :supertester_telemetry_handler_buffers

  @doc """
  Initialize telemetry isolation for the current process.
  """
  @spec setup_telemetry_isolation() :: {:ok, test_id()}
  def setup_telemetry_isolation do
    test_id = System.unique_integer([:positive, :monotonic])
    Process.put(:supertester_telemetry_test_id, test_id)
    IsolationContextStore.update(fn ctx -> %{ctx | telemetry_test_id: test_id} end)
    {:ok, test_id}
  end

  @doc """
  Initialize telemetry isolation and update the isolation context.
  """
  @spec setup_telemetry_isolation(IsolationContext.t()) ::
          {:ok, test_id(), IsolationContext.t()}
  def setup_telemetry_isolation(%IsolationContext{} = ctx) do
    {:ok, test_id} = setup_telemetry_isolation()
    updated_ctx = IsolationContextStore.put_updated(ctx, &%{&1 | telemetry_test_id: test_id})
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
    buffer? = Keyword.get(opts, :buffer, false)
    transform = Keyword.get(opts, :transform, &Function.identity/1)
    buffer_pid = maybe_start_buffer(buffer?)

    # Pass context via config to avoid local function warning from telemetry
    handler_config = %{
      test_id: test_id,
      parent: parent,
      filter_key: filter_key,
      passthrough: passthrough,
      buffer_pid: buffer_pid,
      transform: transform
    }

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        handler_config
      )

    track_handler_buffer(handler_id, buffer_pid)

    Env.on_exit(fn ->
      detach_isolated(handler_id)
    end)

    track_handler(handler_id, events)
    emit_attached(handler_id, events, test_id)
    {:ok, handler_id}
  end

  @doc """
  Detach a telemetry handler attached via `attach_isolated/2` and release any
  associated buffered state.
  """
  @spec detach_isolated(handler_id()) :: :ok
  def detach_isolated(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
    cleanup_handler_buffer(handler_id)
    emit_detached(handler_id)
    :ok
  end

  @doc """
  Flush buffered telemetry messages for a handler created with `buffer: true`.
  """
  @spec flush_buffered_telemetry(handler_id()) :: [telemetry_message()]
  def flush_buffered_telemetry(handler_id) when is_binary(handler_id) do
    case fetch_handler_buffer(handler_id) do
      nil -> []
      buffer_pid -> TelemetryBuffer.drain(buffer_pid)
    end
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, config) do
    %{
      test_id: test_id,
      parent: parent,
      filter_key: filter_key,
      passthrough: passthrough,
      buffer_pid: buffer_pid,
      transform: transform
    } = config

    event_test_id = Map.get(metadata, filter_key)

    should_deliver =
      event_test_id == test_id or
        (passthrough and is_nil(event_test_id))

    if should_deliver do
      message = transform.({:telemetry, event, measurements, metadata})
      deliver_event(parent, message, buffer_pid)
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

    case TelemetryMailbox.receive_matching(event_pattern, metadata_pattern, test_id, timeout) do
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

    case TelemetryMailbox.receive_matching(event_pattern, nil, test_id, timeout) do
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

    events = TelemetryMailbox.collect_matching(event_pattern, test_id, expected_count, timeout)
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
    TelemetryMailbox.flush_all()
  end

  def flush_telemetry(event_pattern) do
    TelemetryMailbox.flush_matching(event_pattern, get_test_id())
  end

  @doc """
  Execute a function and capture emitted telemetry events.
  """
  @spec with_telemetry(event() | [event()], (-> result), attach_opts()) ::
          {result, [telemetry_message()]}
        when result: term()
  def with_telemetry(events, fun, opts \\ []) when is_function(fun, 0) do
    normalized_events = normalize_events(events)
    {:ok, handler_id} = attach_isolated(normalized_events, Keyword.put(opts, :buffer, true))

    try do
      result = fun.()

      receive do
      after
        10 -> :ok
      end

      buffered_events = flush_buffered_telemetry(handler_id)

      events =
        if buffered_events == [] do
          flush_buffer_fallback(normalized_events, get_test_id())
        else
          buffered_events
        end

      {result, events}
    after
      detach_isolated(handler_id)
    end
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
    IsolationContextStore.update(fn ctx ->
      %{ctx | telemetry_handlers: [{handler_id, events} | ctx.telemetry_handlers]}
    end)
  end

  defp maybe_start_buffer(false), do: nil

  defp maybe_start_buffer(true) do
    case TelemetryBuffer.start_link() do
      {:ok, buffer_pid} -> buffer_pid
      {:error, _} -> nil
    end
  end

  defp track_handler_buffer(_handler_id, nil), do: :ok

  defp track_handler_buffer(handler_id, buffer_pid) when is_pid(buffer_pid) do
    TelemetryHandlerBuffers.track(@handler_buffers_key, handler_id, buffer_pid)
  end

  defp fetch_handler_buffer(handler_id) do
    TelemetryHandlerBuffers.fetch(@handler_buffers_key, handler_id)
  end

  defp cleanup_handler_buffer(handler_id) do
    case TelemetryHandlerBuffers.pop(@handler_buffers_key, handler_id) do
      nil -> :ok
      buffer_pid -> TelemetryBuffer.stop(buffer_pid)
    end
  end

  defp flush_buffer_fallback(event_patterns, test_id) do
    TelemetryMailbox.flush_matching_many(event_patterns, test_id)
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

  defp deliver_event(parent, message, nil), do: send(parent, message)

  defp deliver_event(parent, message, buffer_pid) when is_pid(buffer_pid) do
    case TelemetryBuffer.push(buffer_pid, message) do
      :ok -> :ok
      {:error, :buffer_unavailable} -> send(parent, message)
    end
  end
end
