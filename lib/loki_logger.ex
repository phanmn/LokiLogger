defmodule LokiLogger do
  @moduledoc """
  Grafana Loki backend for the Elixir Logger.

  Two integration styles are supported:

  * **Legacy gen_event backend** — keep using `config :logger, backends: [LokiLogger]`.
    The gen_event is now a thin wrapper: it formats the event and forwards it to
    `LokiLogger.Exporter` via a non-blocking cast. All batching, retry, and
    delivery happens in the Exporter.

  * **Modern `:logger` handler** — see `LokiLogger.Handler`. Recommended for new
    projects; `log/2` runs in the producing process so formatting parallelizes
    naturally instead of going through Logger's single backend process.

  Both paths share the same `LokiLogger.Exporter` (and therefore the same Finch
  pool, batch buffer, retry/backoff, overflow queue, and metrics).
  """

  @behaviour :gen_event

  defstruct format: nil,
            level: nil,
            metadata: nil,
            supervisor: nil

  ## :gen_event callbacks

  def init(LokiLogger) do
    case Application.get_env(:logger, :loki_logger) do
      config when is_list(config) and config != [] ->
        {:ok, init(config, %__MODULE__{})}

      _ ->
        # No `:logger, :loki_logger` config — stay dormant rather than
        # silently shipping to `http://localhost:3100`. The caller listed
        # `LokiLogger` in `:logger, backends:` without saying where Loki is.
        {:error, :no_loki_logger_config}
    end
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    case configure_merge(Application.get_env(:logger, :loki_logger) || [], opts) do
      [] ->
        {:error, :no_loki_logger_config}

      config ->
        {:ok, init(config, %__MODULE__{})}
    end
  end

  def handle_call({:configure, options}, state) do
    {:ok, :ok, configure(options, state)}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    if meet_level?(level, state.level) do
      entry = {System.os_time(:nanosecond), format_event(level, msg, ts, md, state)}
      LokiLogger.Exporter.log_event(entry)
    end

    {:ok, state}
  end

  def handle_event(:flush, state) do
    LokiLogger.Exporter.flush_now()
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  ## Public bootstrap (used by LokiLogger.Handler)

  @doc """
  Start the LokiLogger pipeline (Finch pool, Task supervisor, Exporter) on
  demand. Idempotent — returns the existing supervisor pid if already started.

  `opts` is a keyword list merged on top of `Application.get_env(:logger,
  :loki_logger)`.
  """
  def start_pipeline(opts \\ []) do
    config = configure_merge(Application.get_env(:logger, :loki_logger) || [], opts)
    ensure_supervisor(nil, build_loki_url(config), config)
  end

  ## Helpers

  defp meet_level?(_lvl, nil), do: true
  defp meet_level?(lvl, min), do: Logger.compare_levels(lvl, min) != :lt

  defp configure(options, state) do
    config = configure_merge(Application.get_env(:logger, :loki_logger) || [], options)
    Application.put_env(:logger, :loki_logger, config)
    init(config, state)
  end

  defp init(config, state) do
    %{
      state
      | format:
          Logger.Formatter.compile(
            Keyword.get(config, :format, "$time $metadata[$level] $message\n")
          ),
        metadata: Keyword.get(config, :metadata, :all) |> configure_metadata(),
        level: Keyword.get(config, :level, :info),
        supervisor: ensure_supervisor(state.supervisor, build_loki_url(config), config)
    }
  end

  defp build_loki_url(config) do
    Keyword.get(config, :loki_host, "http://localhost:3100") <>
      Keyword.get(config, :loki_path, "/loki/api/v1/push")
  end

  defp ensure_supervisor(sup, _loki_url, _config) when is_pid(sup) do
    # Reuse the running supervisor; runtime reconfigure of network/labels is
    # intentionally not applied to avoid bouncing pools mid-flight.
    if Process.alive?(sup), do: sup, else: nil
  end

  defp ensure_supervisor(_sup, loki_url, config) do
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
       tesla_client: tesla_client(config)}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: LokiLogger.Supervisor) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp configure_metadata(:all), do: :all
  defp configure_metadata(metadata), do: Enum.reverse(metadata)

  defp configure_merge(env, options) do
    Keyword.merge(env, options, fn _, _v1, v2 -> v2 end)
  end

  defp format_event(level, msg, ts, md, %{format: format, metadata: keys}) do
    IO.iodata_to_binary(Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys)))
  end

  defp take_metadata(metadata, :all) do
    Keyword.drop(metadata, [:crash_reason, :ancestors, :callers])
  end

  defp take_metadata(metadata, keys) do
    # Build a map for O(1) lookups; cheaper than O(keys × metadata)
    # Keyword.fetch when metadata is non-trivial.
    map = :maps.from_list(metadata)

    Enum.reduce(keys, [], fn key, acc ->
      case map do
        %{^key => val} -> [{key, val} | acc]
        _ -> acc
      end
    end)
  end

  defp tesla_client(config) do
    http_headers = [
      {"Content-Type", "application/x-protobuf"},
      {"X-Scope-OrgID", Keyword.get(config, :loki_scope_org_id, "fake")}
    ]

    basic_auth_user = Keyword.get(config, :basic_auth_user)
    basic_auth_password = Keyword.get(config, :basic_auth_password)

    case not is_nil(basic_auth_user) and not is_nil(basic_auth_password) do
      true ->
        [
          {Tesla.Middleware.Headers, http_headers},
          {Tesla.Middleware.BasicAuth,
           %{username: basic_auth_user, password: basic_auth_password}}
        ]

      false ->
        [
          {Tesla.Middleware.Headers, http_headers}
        ]
    end
    |> Tesla.client({Tesla.Adapter.Finch, name: LokiLogger.Finch})
  end
end
