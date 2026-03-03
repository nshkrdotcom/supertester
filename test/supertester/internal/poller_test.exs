defmodule Supertester.Internal.PollerTest do
  use ExUnit.Case, async: true

  alias Supertester.Internal.Poller

  test "until/3 retries until :ok is returned" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    assert :ok =
             Poller.until(
               fn ->
                 attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

                 if attempt >= 3, do: :ok, else: :retry
               end,
               100,
               5
             )
  end

  test "until/3 returns {:ok, value} payloads" do
    assert {:ok, :done} =
             Poller.until(
               fn -> {:ok, :done} end,
               50,
               5
             )
  end

  test "until/3 times out when retries never succeed" do
    assert {:error, :timeout} =
             Poller.until(
               fn -> :retry end,
               20,
               5
             )
  end

  test "until/3 propagates explicit errors from checks" do
    assert {:error, :bad_state} =
             Poller.until(
               fn -> {:error, :bad_state} end,
               20,
               5
             )
  end
end
