defmodule Supertester.LoggerIsolation do
  @moduledoc """
  Per-process Logger level isolation utilities for async-safe testing.
  """

  require Logger

  alias Supertester.{Env, IsolationContext, Telemetry, UnifiedTestFoundation}

  @type level ::
          :emergency | :alert | :critical | :error | :warning | :notice | :info | :debug
  @type level_or_all :: level() | :all | :none

  @type isolate_opts :: [
          cleanup: boolean()
        ]

  @type capture_opts :: [
          level: level(),
          colors: boolean(),
          format: String.t(),
          metadata: [atom()]
        ]

  @doc """
  Initialize logger isolation for the current process.
  """
  @spec setup_logger_isolation() :: :ok
  def setup_logger_isolation do
    original_level = Logger.get_process_level(self())
    Process.put(:supertester_logger_original_level, original_level)
    Process.put(:supertester_logger_isolated, true)

    Env.on_exit(fn ->
      restore_level()
    end)

    maybe_update_context(fn ctx ->
      %{ctx | logger_original_level: original_level, logger_isolated?: true}
    end)

    emit_setup()
    :ok
  end

  @doc """
  Initialize logger isolation and update the isolation context.
  """
  @spec setup_logger_isolation(IsolationContext.t()) :: {:ok, IsolationContext.t()}
  def setup_logger_isolation(%IsolationContext{} = ctx) do
    :ok = setup_logger_isolation()
    original_level = Process.get(:supertester_logger_original_level)

    updated_ctx = %{ctx | logger_original_level: original_level, logger_isolated?: true}
    UnifiedTestFoundation.put_isolation_context(updated_ctx)
    {:ok, updated_ctx}
  end

  @doc """
  Set the Logger level for the current process only.
  """
  @spec isolate_level(level_or_all(), isolate_opts()) :: :ok
  def isolate_level(level, opts \\ []) do
    ensure_isolation_setup!()

    Logger.put_process_level(self(), level)

    if Keyword.get(opts, :cleanup, true) and not cleanup_registered?() do
      Env.on_exit(fn -> restore_level() end)
      Process.put(:supertester_logger_cleanup_registered, true)
    end

    emit_level_set(level)
    :ok
  end

  @doc """
  Restore the process Logger level to its original state.
  """
  @spec restore_level() :: :ok
  def restore_level do
    case Process.get(:supertester_logger_original_level) do
      nil ->
        Logger.delete_process_level(self())

      level ->
        Logger.put_process_level(self(), level)
    end

    Process.delete(:supertester_logger_isolated)
    Process.delete(:supertester_logger_original_level)
    Process.delete(:supertester_logger_cleanup_registered)

    maybe_update_context(fn ctx ->
      %{ctx | logger_original_level: nil, logger_isolated?: false}
    end)

    emit_level_restored()
    :ok
  end

  @doc """
  Get the current process isolated level.
  """
  @spec get_isolated_level() :: level() | nil
  def get_isolated_level do
    Logger.get_process_level(self())
  end

  @doc """
  Check if logger isolation is active.
  """
  @spec isolated?() :: boolean()
  def isolated? do
    Process.get(:supertester_logger_isolated, false)
  end

  @doc """
  Capture logs with automatic level isolation.
  """
  @spec capture_isolated(level_or_all(), (-> term()), capture_opts()) :: {String.t(), term()}
  def capture_isolated(level, fun, opts \\ []) when is_function(fun, 0) do
    ensure_isolation_setup!()

    previous_level = get_isolated_level()
    isolate_level(level, cleanup: false)

    try do
      {result, log} = ExUnit.CaptureLog.with_log(opts, fun)
      {log, result}
    after
      restore_previous_level(previous_level)
    end
  end

  @doc """
  Capture logs with automatic level isolation and return only the log.
  """
  @spec capture_isolated!(level_or_all(), (-> term()), capture_opts()) :: String.t()
  def capture_isolated!(level, fun, opts \\ []) when is_function(fun, 0) do
    {log, _result} = capture_isolated(level, fun, opts)
    log
  end

  @doc """
  Execute a function with a temporary Logger level.
  """
  @spec with_level(level_or_all(), (-> result)) :: result when result: term()
  def with_level(level, fun) when is_function(fun, 0) do
    ensure_isolation_setup!()

    previous_level = get_isolated_level()
    isolate_level(level, cleanup: false)

    try do
      fun.()
    after
      restore_previous_level(previous_level)
    end
  end

  @doc """
  Execute a function with a temporary Logger level and capture logs.
  """
  @spec with_level_and_capture(level_or_all(), (-> result)) :: {String.t(), result}
        when result: term()
  def with_level_and_capture(level, fun) when is_function(fun, 0) do
    capture_isolated(level, fun)
  end

  defp ensure_isolation_setup! do
    unless Process.get(:supertester_logger_isolated) do
      raise ArgumentError, """
      Logger isolation not set up. Either:
      1. Use `use Supertester.ExUnitFoundation, logger_isolation: true`
      2. Call `LoggerIsolation.setup_logger_isolation/0` in your setup block
      """
    end
  end

  defp cleanup_registered? do
    Process.get(:supertester_logger_cleanup_registered, false)
  end

  defp restore_previous_level(nil), do: Logger.delete_process_level(self())
  defp restore_previous_level(level), do: Logger.put_process_level(self(), level)

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

  defp emit_setup do
    Telemetry.emit([:logger, :isolation, :setup], %{}, %{pid: self()})
  end

  defp emit_level_set(level) do
    Telemetry.emit([:logger, :level, :set], %{}, %{pid: self(), level: level})
  end

  defp emit_level_restored do
    Telemetry.emit([:logger, :level, :restored], %{}, %{pid: self()})
  end
end
