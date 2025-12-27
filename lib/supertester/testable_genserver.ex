defmodule Supertester.TestableGenServer do
  @moduledoc """
  A behavior that makes GenServers testable with Supertester.

  This module injects a `__supertester_sync__` handler that allows tests to
  synchronize with the GenServer without using `Process.sleep/1`.

  ## Usage

      defmodule MyServer do
        use GenServer
        use Supertester.TestableGenServer

        # Your GenServer implementation
      end

  ## Synchronization

  The injected handler responds to two message formats:

  - `:__supertester_sync__` - Returns `:ok` after processing
  - `{:__supertester_sync__, return_state: true}` - Returns `{:ok, state}`

  ## Example

      {:ok, server} = MyServer.start_link()
      GenServer.cast(server, :some_operation)

      # Ensure cast is processed before continuing
      GenServer.call(server, :__supertester_sync__)

      # Now safe to verify results
      state = :sys.get_state(server)
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      @doc """
      Supertester synchronization handler.

      This handler is injected by `use Supertester.TestableGenServer` and allows
      tests to synchronize with this GenServer without using `Process.sleep/1`.

      ## Messages

      - `:__supertester_sync__` - Returns `:ok`
      - `{:__supertester_sync__, return_state: true}` - Returns `{:ok, state}`
      """
      @before_compile Supertester.TestableGenServer
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # Only define if not already defined by user
      if Module.defines?(__MODULE__, {:handle_call, 3}) do
        # User has handle_call, prepend our clauses
        defoverridable handle_call: 3

        def handle_call(:__supertester_sync__, _from, state) do
          {:reply, :ok, state}
        end

        def handle_call({:__supertester_sync__, opts}, _from, state) do
          if Keyword.get(opts, :return_state, false) do
            {:reply, {:ok, state}, state}
          else
            {:reply, :ok, state}
          end
        end

        # Delegate to original handle_call for other messages
        def handle_call(msg, from, state) do
          super(msg, from, state)
        end
      else
        def handle_call(:__supertester_sync__, _from, state) do
          {:reply, :ok, state}
        end

        def handle_call({:__supertester_sync__, opts}, _from, state) do
          if Keyword.get(opts, :return_state, false) do
            {:reply, {:ok, state}, state}
          else
            {:reply, :ok, state}
          end
        end
      end
    end
  end
end
