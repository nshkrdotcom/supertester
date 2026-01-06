defmodule EchoLab.LoggerIsolationTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.LoggerIsolation

  require Logger

  test "setup_logger_isolation updates context", context do
    {:ok, updated} = setup_logger_isolation(context.isolation_context)
    assert updated.logger_isolated?
  end

  test "logger isolation helpers" do
    :ok = setup_logger_isolation()

    assert isolated?()
    assert get_isolated_level() == Logger.get_process_level(self())

    :ok = isolate_level(:debug)
    assert get_isolated_level() == :debug

    {log, :ok} =
      capture_isolated(:info, fn ->
        Logger.info("captured")
        :ok
      end)

    assert log =~ "captured"

    assert capture_isolated!(:info, fn ->
             Logger.info("only log")
             :ok
           end) =~ "only log"

    {log2, :ok} =
      with_level_and_capture(:info, fn ->
        Logger.info("with level")
        :ok
      end)

    assert log2 =~ "with level"

    :ok = with_level(:error, fn -> :ok end)

    :ok = restore_level()
    refute isolated?()
  end
end
