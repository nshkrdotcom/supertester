defmodule EchoLab.Names do
  @moduledoc false

  @spec child_name(String.t() | atom(), atom()) :: atom()
  def child_name(prefix, suffix) do
    "#{prefix}_#{suffix}"
    |> String.to_atom()
  end
end
