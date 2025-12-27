defmodule Supertester.LoggerIsolationTest do
  use ExUnit.Case, async: true

  require Logger

  alias Supertester.{IsolationContext, LoggerIsolation}

  describe "setup_logger_isolation/0" do
    test "marks isolation as active and stores original level" do
      original = Logger.get_process_level(self())

      assert :ok = LoggerIsolation.setup_logger_isolation()
      assert LoggerIsolation.isolated?()
      assert Process.get(:supertester_logger_original_level) == original
    end
  end

  describe "setup_logger_isolation/1" do
    test "updates the isolation context" do
      ctx = %IsolationContext{test_id: :logger_test}

      {:ok, updated_ctx} = LoggerIsolation.setup_logger_isolation(ctx)

      assert updated_ctx.logger_isolated?
      assert updated_ctx.logger_original_level == Logger.get_process_level(self())
    end
  end

  describe "level management" do
    setup do
      LoggerIsolation.setup_logger_isolation()
      :ok
    end

    test "isolate_level/1 sets the process level" do
      LoggerIsolation.isolate_level(:debug)
      assert LoggerIsolation.get_isolated_level() == :debug
    end

    test "restore_level/0 returns to the original level" do
      original = Logger.get_process_level(self())

      LoggerIsolation.isolate_level(:error)
      LoggerIsolation.restore_level()

      assert Logger.get_process_level(self()) == original
      refute LoggerIsolation.isolated?()
    end

    test "with_level/2 scopes the level change" do
      original = Logger.get_process_level(self())

      result =
        LoggerIsolation.with_level(:error, fn ->
          assert LoggerIsolation.get_isolated_level() == :error
          :ok
        end)

      assert result == :ok
      assert Logger.get_process_level(self()) == original
    end
  end

  describe "log capture" do
    setup do
      LoggerIsolation.setup_logger_isolation()
      :ok
    end

    test "capture_isolated/2 returns log and result" do
      {log, result} =
        LoggerIsolation.capture_isolated(:debug, fn ->
          Logger.debug("debug message")
          :done
        end)

      assert log =~ "debug message"
      assert result == :done
    end

    test "capture_isolated!/2 returns only the log" do
      log =
        LoggerIsolation.capture_isolated!(:info, fn ->
          Logger.info("info message")
        end)

      assert log =~ "info message"
    end

    test "with_level_and_capture/2 combines level and capture" do
      {log, result} =
        LoggerIsolation.with_level_and_capture(:debug, fn ->
          Logger.debug("wrapped")
          :ok
        end)

      assert log =~ "wrapped"
      assert result == :ok
    end
  end
end
