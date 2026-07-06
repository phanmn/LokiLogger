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
  pool, batch buffer, retry/backoff, overflow queue, and metrics). The whole
  pipeline runs under `LokiLogger.AppSupervisor` with permanent restart, so a
  crash in the Exporter/Finch doesn't leave the handler dangling.
  """

  @behaviour :gen_event

  defstruct format: nil,
            level: nil,
            metadata: nil

  ## :gen_event callbacks

  def init(LokiLogger) do
    case Application.get_env(:logger, :loki_logger) do
      config when is_list(config) and config != [] ->
        {:ok, init(config, %__MODULE__{})}

      _ ->
        # No `:logger, :loki_logger` config — stay dormant rather than
        # silently shipping to `http://localhost:3100`.
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
      entry = {System.os_time(:nanosecond), format_event(level, msg, ts, md, state), to_string(level)}
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

  ## Public bootstrap (used by LokiLogger.Application and LokiLogger.Handler)

  @doc """
  Ensure the LokiLogger pipeline (Finch pool, Task supervisor, Exporter) is
  running, adding it as a permanent child of `LokiLogger.AppSupervisor` so OTP
  will restart it on crash. Idempotent — returns the existing supervisor pid
  if already started.

  `opts` is a keyword list merged on top of `Application.get_env(:logger,
  :loki_logger)`. Note that opts are only applied when the pipeline is being
  *created*; an already-running pipeline keeps its original config.
  """
  def start_pipeline(opts \\ []) do
    case Process.whereis(LokiLogger.Supervisor) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Process.whereis(LokiLogger.AppSupervisor) do
          nil ->
            # AppSupervisor hasn't started yet — we're being called during
            # :logger boot, before our own :loki_logger app started. Returning
            # nil here keeps us from creating an orphan standalone Pipeline
            # that would escape AppSupervisor's permanent supervision.
            # LokiLogger.Application.start/2 will attach the pipeline once
            # the OTP application boots.
            nil

          _ ->
            config = configure_merge(Application.get_env(:logger, :loki_logger) || [], opts)

            if config == [] do
              raise ArgumentError,
                    "LokiLogger.start_pipeline/1 called without :logger, :loki_logger config " <>
                      "(and no opts supplied)"
            end

            attach_pipeline(config)
        end
    end
  end

  defp attach_pipeline(config) do
    child_spec = %{
      id: LokiLogger.Pipeline,
      start: {LokiLogger.Pipeline, :start_link, [config]},
      restart: :permanent,
      type: :supervisor
    }

    case Supervisor.start_child(LokiLogger.AppSupervisor, child_spec) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, :already_present} ->
        # Spec exists but the child was terminated; restart it.
        case Supervisor.restart_child(LokiLogger.AppSupervisor, LokiLogger.Pipeline) do
          {:ok, pid} -> pid
          {:ok, pid, _info} -> pid
          {:error, :running} -> Process.whereis(LokiLogger.Supervisor)
        end
    end
  end

  ## Internal helpers (exposed for LokiLogger.Pipeline; treat as @doc false)

  @doc false
  def build_loki_url(config) do
    Keyword.get(config, :loki_host, "http://localhost:3100") <>
      Keyword.get(config, :loki_path, "/loki/api/v1/push")
  end

  @doc false
  def tesla_client(config) do
    # Only send X-Scope-OrgID when explicitly configured. Loki accepts any string
    # tenant, but VictoriaLogs requires a numeric AccountID and rejects the batch
    # with a 400 otherwise — so omit the header entirely when unset.
    org_id_header =
      case Keyword.get(config, :loki_scope_org_id) do
        nil -> []
        org_id -> [{"X-Scope-OrgID", to_string(org_id)}]
      end

    http_headers = [{"Content-Type", "application/x-protobuf"} | org_id_header]

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

  ## Private

  defp meet_level?(_lvl, nil), do: true
  defp meet_level?(lvl, min), do: Logger.compare_levels(lvl, min) != :lt

  defp configure(options, state) do
    config = configure_merge(Application.get_env(:logger, :loki_logger) || [], options)
    Application.put_env(:logger, :loki_logger, config)
    init(config, state)
  end

  defp init(config, state) do
    # Safety net: ensure the pipeline is up. If the LokiLogger app already
    # started it as a permanent child of AppSupervisor (the typical case),
    # this is a no-op. If config arrived after Application.start/2 ran,
    # this attaches the pipeline now.
    _ = start_pipeline()

    %{
      state
      | format:
          Logger.Formatter.compile(
            Keyword.get(config, :format, "$time $metadata[$level] $message\n")
          ),
        metadata: Keyword.get(config, :metadata, :all) |> configure_metadata(),
        level: Keyword.get(config, :level, :info)
    }
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
end
