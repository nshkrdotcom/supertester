defmodule SupertesterTest do
  use ExUnit.Case, async: true
  doctest Supertester

  test "version/0 returns the version" do
    version = Supertester.version()
    assert is_binary(version)
    assert version == "0.1.0"
  end
end
