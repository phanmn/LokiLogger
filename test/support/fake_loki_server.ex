defmodule LokiLogger.FakeLokiServer do
  @moduledoc """
  An in-process HTTP server that mimics Loki's `/loki/api/v1/push` endpoint.

  Decodes the snappy-compressed protobuf request body into a
  `Logproto.PushRequest` struct and forwards it (plus the raw headers) to a
  subscribed test pid. Lets you queue specific response statuses to drive
  retry/error tests.

  Typical use:

      {:ok, _pid, url} = LokiLogger.FakeLokiServer.start()
      LokiLogger.FakeLokiServer.listen_with(self())

      # ...drive LokiLogger to push something to `url`...

      assert_receive {:loki_push, {:ok, push_request}, headers}, 1_000
  """

  use Plug.Router

  @table __MODULE__

  ## Test-side API

  def start(opts \\ []) do
    init_state()
    port = Keyword.get_lazy(opts, :port, &find_free_port/0)

    case Bandit.start_link(plug: __MODULE__, port: port, ip: {127, 0, 0, 1}) do
      {:ok, pid} -> {:ok, pid, "http://127.0.0.1:#{port}"}
      error -> error
    end
  end

  @doc "Send decoded pushes to this pid via `send/2`."
  def listen_with(pid) when is_pid(pid) do
    init_state()
    :ets.insert(@table, {:listener, pid})
    :ok
  end

  @doc """
  Queue a response. The fake server will return responses in FIFO order;
  once the queue is empty, it returns `204 No Content`.
  """
  def queue_response(status, body \\ "") do
    init_state()
    [{:responses, q}] = :ets.lookup(@table, :responses)
    :ets.insert(@table, {:responses, :queue.in({status, body}, q)})
    :ok
  end

  @doc "Empty the response queue and detach the listener pid."
  def reset do
    init_state()
    :ets.insert(@table, {:listener, nil})
    :ets.insert(@table, {:responses, :queue.new()})
    :ok
  end

  ## Plug router

  plug(:match)
  plug(:dispatch)

  post "/loki/api/v1/push" do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

    decoded = decode_push(body)

    case listener() do
      nil -> :ok
      pid -> send(pid, {:loki_push, decoded, conn.req_headers})
    end

    {status, resp_body} = pop_response()
    send_resp(conn, status, resp_body)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## Internals

  defp decode_push(body) do
    try do
      {:ok, decompressed} = :snappyer.decompress(body)
      {:ok, Logproto.PushRequest.decode!(decompressed)}
    rescue
      e -> {:error, e}
    end
  end

  defp listener do
    case :ets.lookup(@table, :listener) do
      [{:listener, pid}] -> pid
      _ -> nil
    end
  end

  defp pop_response do
    [{:responses, q}] = :ets.lookup(@table, :responses)

    case :queue.out(q) do
      {{:value, resp}, q2} ->
        :ets.insert(@table, {:responses, q2})
        resp

      {:empty, _} ->
        {204, ""}
    end
  end

  defp init_state do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])
        :ets.insert(@table, {:listener, nil})
        :ets.insert(@table, {:responses, :queue.new()})

      _ ->
        :ok
    end
  end

  defp find_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end
end
