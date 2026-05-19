defmodule LokiLogger.IntegrationTest do
  use ExUnit.Case, async: false

  alias LokiLogger.FakeLokiServer

  setup do
    # The repo's config.exs wires the gen_event LokiLogger backend at boot,
    # pointing at the default Loki URL. Detach it so it doesn't fight with
    # our per-test fresh pipeline.
    Logger.remove_backend(LokiLogger)
    stop_pipeline()
    FakeLokiServer.reset()

    {:ok, server_pid, url} = FakeLokiServer.start()
    FakeLokiServer.listen_with(self())

    on_exit(fn ->
      stop_pipeline()
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
    end)

    {:ok, url: url}
  end

  test "logs are batched and pushed to Loki with the configured labels", %{url: url} do
    start_pipeline(url,
      loki_labels: %{app: "test", node: "node1"},
      max_buffer: 2,
      flush_interval_ms: 0
    )

    LokiLogger.Exporter.log_event({100_000_000_000, "first line"})
    LokiLogger.Exporter.log_event({200_000_000_000, "second line"})

    push = assert_push_received()

    [stream] = push.streams
    # Labels in the protobuf body are a single string; the order of keys
    # within is determined by Map iteration, so we just check both keys appear.
    assert stream.labels =~ ~s(app="test")
    assert stream.labels =~ ~s(node="node1")

    lines = Enum.map(stream.entries, & &1.line)
    assert lines == ["first line", "second line"]

    # Timestamps round-trip as {seconds, nanos}.
    [first, second] = stream.entries
    assert first.timestamp.seconds == 100
    assert first.timestamp.nanos == 0
    assert second.timestamp.seconds == 200
  end

  test "X-Scope-OrgID header is forwarded", %{url: url} do
    start_pipeline(url,
      loki_labels: %{app: "tenant-test"},
      loki_scope_org_id: "tenant-42",
      max_buffer: 1,
      flush_interval_ms: 0
    )

    LokiLogger.Exporter.log_event({1_000_000_000, "hello"})

    {_push, headers} = assert_push_received_with_headers()
    assert {"x-scope-orgid", "tenant-42"} in headers
  end

  test "503 is retried then succeeds", %{url: url} do
    FakeLokiServer.queue_response(503, "service unavailable")
    FakeLokiServer.queue_response(204, "")

    start_pipeline(url,
      loki_labels: %{app: "retry"},
      max_buffer: 1,
      flush_interval_ms: 0,
      max_retries: 3,
      retry_base_ms: 5
    )

    LokiLogger.Exporter.log_event({1_000_000_000, "retry me"})

    # First push -> 503
    _first = assert_push_received(500)
    # Retry push -> 204
    _retry = assert_push_received(500)
  end

  test "400 is NOT retried (client errors are dropped)", %{url: url} do
    FakeLokiServer.queue_response(400, "bad request")

    start_pipeline(url,
      loki_labels: %{app: "no-retry"},
      max_buffer: 1,
      flush_interval_ms: 0,
      max_retries: 3,
      retry_base_ms: 5
    )

    LokiLogger.Exporter.log_event({1_000_000_000, "give up"})

    _push = assert_push_received(500)
    refute_receive {:loki_push, _, _}, 200
  end

  test "time-based flush ships a partial buffer", %{url: url} do
    start_pipeline(url,
      loki_labels: %{app: "timer"},
      max_buffer: 1_000,
      flush_interval_ms: 50
    )

    LokiLogger.Exporter.log_event({1_000_000_000, "trickled"})

    push = assert_push_received(500)
    [stream] = push.streams
    assert [%{line: "trickled"}] = stream.entries
  end

  ## Helpers

  defp start_pipeline(url, opts) do
    Application.put_env(:logger, :loki_logger, [{:loki_host, url} | opts])
    LokiLogger.start_pipeline()
  end

  defp stop_pipeline do
    case Process.whereis(LokiLogger.AppSupervisor) do
      nil ->
        # Test ran without the LokiLogger application started — fall back
        # to stopping a standalone pipeline supervisor.
        if pid = Process.whereis(LokiLogger.Supervisor) do
          try do
            Supervisor.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

      _app_sup ->
        # Detach the Pipeline child from AppSupervisor so it stays gone
        # until the next start_pipeline/1 call. terminate_child + delete_child
        # both return :ok or {:error, :not_found}; both are fine here.
        Supervisor.terminate_child(LokiLogger.AppSupervisor, LokiLogger.Pipeline)
        Supervisor.delete_child(LokiLogger.AppSupervisor, LokiLogger.Pipeline)
    end
  end

  defp assert_push_received(timeout \\ 1_000) do
    {push, _headers} = assert_push_received_with_headers(timeout)
    push
  end

  defp assert_push_received_with_headers(timeout \\ 1_000) do
    receive do
      {:loki_push, {:ok, push}, headers} -> {push, headers}
      {:loki_push, {:error, reason}, _} -> flunk("fake server failed to decode: #{inspect(reason)}")
    after
      timeout -> flunk("no Loki push received within #{timeout}ms")
    end
  end
end
