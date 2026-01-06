defmodule EchoLab.SupertesterVersionTest do
  use ExUnit.Case, async: true

  test "supertester version is exposed" do
    assert is_binary(Supertester.version())
  end
end
