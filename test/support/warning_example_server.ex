defmodule Supertester.WarningExampleServer do
  @moduledoc """
  Example used to reproduce the @doc on private function warning.

  The warning was caused by a stale @doc attribute attaching to
  `__supertester_sync_reply__/2`. This is now cleared before generating
  the private helper, so compiling this module should be silent.

  This pattern (using TestableGenServer without GenServer) is used when you
  want to create a minimal shim that injects the __supertester_sync__ handler
  into tests without implementing a full GenServer.
  """

  use Supertester.TestableGenServer
end
