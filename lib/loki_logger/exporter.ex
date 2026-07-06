defmodule LokiLogger.Exporter do
  @moduledoc false

  use GenServer

  defmodule State do
    @type t :: %__MODULE__{
            tesla_client: any(),
            loki_url: bitstring(),
            loki_labels: any(),
            max_buffer: pos_integer(),
            max_concurrency: pos_integer(),
            max_overflow: non_neg_integer(),
            flush_interval_ms: non_neg_integer(),
            max_retries: non_neg_integer(),
            retry_base_ms: pos_integer(),
            pending: list(),
            pending_size: non_neg_integer(),
            buffers: :queue.queue(),
            buffers_size: non_neg_integer(),
            in_flight: %{reference() => true},
            dropped: non_neg_integer()
          }

    defstruct tesla_client: nil,
              loki_url: nil,
              loki_labels: nil,
              max_buffer: 300,
              max_concurrency: 4,
              max_overflow: 100,
              flush_interval_ms: 5_000,
              max_retries: 3,
              retry_base_ms: 200,
              pending: [],
              pending_size: 0,
              buffers: :queue.new(),
              buffers_size: 0,
              in_flight: %{},
              dropped: 0
  end

  ## Public API

  @doc """
  Enqueue a single `{epoch_nanoseconds, line}` entry for delivery.
  Called by both the gen_event backend and the `:logger` handler.
  """
  def log_event(entry) do
    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc """
  Immediately flush whatever's pending into the in-flight pipeline.
  """
  def flush_now do
    GenServer.cast(__MODULE__, :flush_now)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init(config) do
    state = %State{
      tesla_client: Keyword.fetch!(config, :tesla_client),
      loki_url: Keyword.fetch!(config, :loki_url),
      loki_labels: Keyword.fetch!(config, :loki_labels),
      max_buffer: Keyword.get(config, :max_buffer, 300),
      max_concurrency: Keyword.get(config, :max_concurrency, 4),
      max_overflow: Keyword.get(config, :max_overflow, 100),
      flush_interval_ms: Keyword.get(config, :flush_interval_ms, 5_000),
      max_retries: Keyword.get(config, :max_retries, 3),
      retry_base_ms: Keyword.get(config, :retry_base_ms, 200)
    }

    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:log, entry}, %State{} = state) do
    pending_size = state.pending_size + 1
    state = %{state | pending: [entry | state.pending], pending_size: pending_size}

    state =
      if pending_size >= state.max_buffer do
        flush_pending(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:flush_now, %State{} = state) do
    {:noreply, flush_pending(state)}
  end

  @impl true
  def handle_info(:loki_flush_tick, %State{} = state) do
    state = flush_pending(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, %State{} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, task_done(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, task_done(state, ref)}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  ## Internals

  defp schedule_flush(0), do: :ok
  defp schedule_flush(nil), do: :ok

  defp schedule_flush(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :loki_flush_tick, interval)
    :ok
  end

  defp flush_pending(%State{pending_size: 0} = state), do: state

  defp flush_pending(%State{} = state) do
    batch = state.pending
    state = %{state | pending: [], pending_size: 0}
    submit_batch(state, batch)
  end

  defp submit_batch(%State{} = state, batch) do
    cond do
      map_size(state.in_flight) < state.max_concurrency ->
        push(state, batch)

      state.buffers_size < state.max_overflow ->
        %{
          state
          | buffers: :queue.in(batch, state.buffers),
            buffers_size: state.buffers_size + 1
        }

      true ->
        # Overflow: drop the oldest queued batch to make room for the newest.
        {{:value, _dropped}, rest} = :queue.out(state.buffers)

        %{
          state
          | buffers: :queue.in(batch, rest),
            dropped: state.dropped + 1
        }
    end
  end

  defp task_done(%State{} = state, ref) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        state

      {_, in_flight} ->
        state = %{state | in_flight: in_flight}

        case :queue.out(state.buffers) do
          {:empty, _} ->
            state

          {{:value, batch}, rest} ->
            push(%{state | buffers: rest, buffers_size: state.buffers_size - 1}, batch)
        end
    end
  end

  defp push(%State{} = state, batch) do
    %State{
      tesla_client: tesla_client,
      loki_url: loki_url,
      loki_labels: loki_labels,
      max_retries: max_retries,
      retry_base_ms: retry_base_ms
    } = state

    body = generate_bin_push_request(loki_labels, batch)

    task =
      Task.Supervisor.async_nolink(LokiLogger.TaskSupervisor, fn ->
        do_push(tesla_client, loki_url, body, max_retries, retry_base_ms)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, true)}
  end

  defp do_push(client, url, body, retries_left, delay_ms) do
    case Tesla.post(client, url, body) do
      {:ok, %Tesla.Env{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %Tesla.Env{status: status, body: rbody}}
      when status == 429 or status >= 500 ->
        # Transient (server-side or rate limited) — retry with exponential
        # backoff + jitter. Other 4xx falls through to the drop clause since
        # those won't succeed on retry.
        if retries_left > 0 do
          jitter_sleep(delay_ms)
          do_push(client, url, body, retries_left - 1, delay_ms * 2)
        else
          IO.puts(
            :stderr,
            "LokiLogger: giving up after retries, status #{status}: #{inspect(rbody)}"
          )
        end

      {:ok, %Tesla.Env{status: status, body: rbody}} ->
        IO.puts(
          :stderr,
          "LokiLogger: dropping batch, client error #{status}: #{inspect(rbody)}"
        )

      {:error, reason} ->
        if retries_left > 0 do
          jitter_sleep(delay_ms)
          do_push(client, url, body, retries_left - 1, delay_ms * 2)
        else
          IO.puts(:stderr, "LokiLogger: giving up after retries: #{inspect(reason)}")
        end

      other ->
        IO.puts(:stderr, "LokiLogger: unexpected result: #{inspect(other)}")
    end
  end

  defp jitter_sleep(delay_ms) do
    jitter = :rand.uniform(max(1, div(delay_ms, 2)))
    :timer.sleep(delay_ms + jitter)
  end

  defp generate_bin_push_request(loki_labels, output) do
    labels =
      loki_labels
      |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"" end)
      |> Enum.join(",")

    labels = "{" <> labels <> "}"

    # Entries arrive newest-first (prepended); sort once by ts so Loki accepts them.
    sorted_entries =
      output
      |> List.keysort(0)
      |> Enum.map(fn {ts, line} ->
        seconds = div(ts, 1_000_000_000)
        nanos = ts - seconds * 1_000_000_000

        %Logproto.EntryAdapter{
          timestamp: %Google.Protobuf.Timestamp{seconds: seconds, nanos: nanos},
          line: line
        }
      end)

    request = %Logproto.PushRequest{
      streams: [
        %Logproto.StreamAdapter{
          labels: labels,
          entries: sorted_entries
        }
      ]
    }

    {:ok, bin_push_request} =
      request
      |> Logproto.PushRequest.encode!()
      |> IO.iodata_to_binary()
      |> :snappyer.compress()

    bin_push_request
  end
end
