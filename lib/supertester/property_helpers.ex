defmodule Supertester.PropertyHelpers do
  @moduledoc """
  StreamData generators tailored for Supertester's concurrent harness.
  """

  alias Supertester.ConcurrentHarness
  alias StreamData

  @doc """
  Generates sequences of GenServer operations suitable for ConcurrentHarness threads.

  ## Options

  * `:default_operation` - Tag bare terms as `:call` or `:cast` (default: `:call`)
  * `:min_length` / `:max_length` - Bounds for sequence length
  """
  @spec genserver_operation_sequence([term() | ConcurrentHarness.operation()], keyword()) ::
          StreamData.t([ConcurrentHarness.operation()])
  def genserver_operation_sequence(operations, opts \\ []) when is_list(operations) do
    ensure_stream_data!()

    default_operation = Keyword.get(opts, :default_operation, :call)
    min_length = Keyword.get(opts, :min_length, 1)
    max_length = Keyword.get(opts, :max_length, max(min_length, 5))

    normalized =
      Enum.map(operations, fn op ->
        ConcurrentHarness.normalize_operation(op, default_operation)
      end)

    normalized
    |> StreamData.member_of()
    |> StreamData.list_of(min_length: min_length, max_length: max_length)
  end

  @doc """
  Generates concurrent scenario configs consumable by `ConcurrentHarness.from_property_config/3`.

  ## Options

  * `:operations` - Required list passed to `genserver_operation_sequence/2`
  * `:min_threads` / `:max_threads` - Thread bounds (defaults: 2..4)
  * `:min_ops_per_thread` / `:max_ops_per_thread`
  * `:call_timeout_ms`, `:timeout_ms`, `:metadata`, `:mailbox`
  """
  @spec concurrent_scenario(keyword()) :: StreamData.t(map())
  def concurrent_scenario(opts) do
    ensure_stream_data!()

    operations = Keyword.fetch!(opts, :operations)
    min_threads = opts |> Keyword.get(:min_threads, 2) |> max(1)
    max_threads = opts |> Keyword.get(:max_threads, max(min_threads, 4)) |> max(min_threads)
    min_ops = opts |> Keyword.get(:min_ops_per_thread, 1) |> max(1)
    max_ops = opts |> Keyword.get(:max_ops_per_thread, max(min_ops, 5)) |> max(min_ops)

    op_seq_opts = [
      default_operation: Keyword.get(opts, :default_operation, :call),
      min_length: min_ops,
      max_length: max_ops
    ]

    operations_gen = genserver_operation_sequence(operations, op_seq_opts)

    StreamData.integer(min_threads..max_threads)
    |> StreamData.bind(fn thread_count ->
      StreamData.map(StreamData.list_of(operations_gen, length: thread_count), fn scripts ->
        %{
          thread_scripts: scripts,
          timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
          call_timeout_ms: Keyword.get(opts, :call_timeout_ms, 1_000),
          metadata: Keyword.get(opts, :metadata, %{}),
          mailbox: Keyword.get(opts, :mailbox),
          default_operation: Keyword.get(opts, :default_operation, :call)
        }
      end)
    end)
  end

  defp ensure_stream_data! do
    unless Code.ensure_loaded?(StreamData) do
      raise ArgumentError,
            "Supertester.PropertyHelpers requires :stream_data. Add {:stream_data, \"~> 1.0\", only: :test} to your dependencies."
    end
  end
end
