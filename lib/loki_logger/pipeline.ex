defmodule LokiLogger.Pipeline do
  @moduledoc false

  use Supervisor

  def start_link(config) when is_list(config) do
    Supervisor.start_link(__MODULE__, config, name: LokiLogger.Supervisor)
  end

  @impl true
  def init(config) do
    loki_url = LokiLogger.build_loki_url(config)
    pool_size = Keyword.get(config, :pool_size, 16)
    pool_count = Keyword.get(config, :pool_count, 4)

    children = [
      {Finch,
       name: LokiLogger.Finch,
       pools: %{
         loki_url => [size: pool_size, count: pool_count, pool_max_idle_time: 10_000]
       }},
      {Task.Supervisor, name: LokiLogger.TaskSupervisor},
      {LokiLogger.Exporter,
       loki_labels: Keyword.get(config, :loki_labels, %{application: "loki_logger_library"}),
       loki_url: loki_url,
       max_buffer: Keyword.get(config, :max_buffer, 300),
       max_concurrency: Keyword.get(config, :max_concurrency, pool_count),
       max_overflow: Keyword.get(config, :max_overflow, 100),
       flush_interval_ms: Keyword.get(config, :flush_interval_ms, 5_000),
       max_retries: Keyword.get(config, :max_retries, 3),
       retry_base_ms: Keyword.get(config, :retry_base_ms, 200),
       tesla_client: LokiLogger.tesla_client(config)}
    ]

    # Generous restart budget so a transient burst of failures (a Loki
    # outage, a snappyer NIF hiccup) doesn't take the supervisor down
    # permanently — the previous default of 3-in-5s caused exactly that.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60
    )
  end
end
