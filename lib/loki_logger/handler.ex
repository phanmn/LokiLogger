defmodule LokiLogger.Handler do
  @moduledoc """
  An OTP `:logger` handler that delivers logs to Grafana Loki.

  Modern alternative to the gen_event `LokiLogger` backend. The `log/2`
  callback runs in the **producing process**, so formatting parallelizes
  naturally rather than going through Logger's single backend process.

  Shares `LokiLogger.Exporter` (and therefore Finch pool, batch buffer,
  retry/backoff, overflow queue) with the gen_event backend — but don't
  enable both at once, or every event ships twice.

  ## Three ways to wire it up

  **1. Config-driven auto-install** (recommended — mirrors the gen_event UX):

      config :logger, :loki_logger,
        level: :info,
        format: "$time $metadata[$level] $message\\n",
        metadata: :all,
        loki_host: "http://localhost:3100",
        loki_labels: %{application: "my_app"}

  No code in your app. `LokiLogger.Application` installs the handler at
  boot whenever `:logger, :loki_logger` is configured and `LokiLogger` is
  **not** in `config :logger, backends: [...]` (which would otherwise mean
  the user opted into the legacy gen_event path).

  **2. Explicit programmatic install** (same Application env, your control):

      LokiLogger.Handler.install()

  Useful if you want to defer install until after runtime secrets are loaded.

  **3. Raw OTP API** (bypass Application env entirely):

      :logger.add_handler(:loki, LokiLogger.Handler, %{
        level: :info,
        config: %{loki_host: "...", loki_labels: %{...}}
      })
  """

  alias LokiLogger.Exporter

  @default_format "$time $metadata[$level] $message\n"

  @drop_meta_default [
    :time,
    :gl,
    :mfa,
    :report_cb,
    :crash_reason,
    :ancestors,
    :callers,
    :domain
  ]

  ## Public install helper

  @doc """
  Install this module as a `:logger` handler, reading defaults from
  `Application.get_env(:logger, :loki_logger)`. Idempotent — if a handler
  with the given id already exists, returns `:ok`.

  `opts` (keyword list) override the Application env.
  """
  def install(handler_id \\ :loki_logger, opts \\ []) do
    base = Application.get_env(:logger, :loki_logger, [])
    merged = Keyword.merge(base, opts)

    if merged == [] do
      # No `:logger, :loki_logger` config at all — refuse rather than
      # silently shipping to default `http://localhost:3100`.
      {:error, :no_loki_logger_config}
    else
      level = Keyword.get(merged, :level, :info)

      config_map =
        merged
        |> Keyword.drop([:install_handler, :handler_id, :level])
        |> Map.new()

      case :logger.add_handler(handler_id, __MODULE__, %{level: level, config: config_map}) do
        :ok -> :ok
        # OTP returns `:already_exist` (singular) when a handler with this
        # id is already registered — treat that as success for idempotency.
        {:error, {:already_exist, _}} -> :ok
        {:error, {:already_exists, _}} -> :ok
        error -> error
      end
    end
  end

  ## :logger.handler callbacks

  def adding_handler(handler_config) do
    user_config = Map.get(handler_config, :config, %{})
    user_opts = Map.to_list(user_config)

    try do
      _pid = LokiLogger.start_pipeline(user_opts)

      compiled_format =
        user_config
        |> Map.get(:format, @default_format)
        |> Logger.Formatter.compile()

      metadata_keys =
        case Map.get(user_config, :metadata, :all) do
          :all -> :all
          keys when is_list(keys) -> Enum.reverse(keys)
        end

      enriched_config =
        user_config
        |> Map.put(:__compiled_format__, compiled_format)
        |> Map.put(:__metadata_keys__, metadata_keys)

      {:ok, Map.put(handler_config, :config, enriched_config)}
    rescue
      e ->
        {:error, {:loki_logger_start_failed, Exception.message(e)}}
    end
  end

  def removing_handler(_handler_config), do: :ok

  def changing_config(_set_or_update, _old_config, new_config), do: {:ok, new_config}

  def log(%{level: level, msg: msg, meta: meta}, %{config: config}) do
    line = format_line(level, msg, meta, config)

    ts =
      case Map.get(meta, :time) do
        # :logger timestamps are microseconds since epoch (UTC)
        t when is_integer(t) -> t * 1_000
        _ -> System.os_time(:nanosecond)
      end

    Exporter.log_event({ts, line, to_string(downgrade_level(level))})
    :ok
  end

  ## Formatting

  defp format_line(level, msg, meta, config) do
    format = Map.fetch!(config, :__compiled_format__)
    metadata_keys = Map.get(config, :__metadata_keys__, :all)

    msg_iodata = msg_to_iodata(msg)
    ts_tuple = ts_from_meta(meta)
    md_kw = filter_metadata(meta, metadata_keys)
    logger_level = downgrade_level(level)

    format
    |> Logger.Formatter.format(logger_level, msg_iodata, ts_tuple, md_kw)
    |> IO.iodata_to_binary()
  end

  defp msg_to_iodata({:string, s}), do: s
  defp msg_to_iodata({:report, %{} = r}), do: inspect(r)
  defp msg_to_iodata({:report, r}) when is_list(r), do: inspect(r)

  defp msg_to_iodata({format, args}) do
    try do
      :io_lib.format(format, args)
    rescue
      _ -> inspect({format, args})
    end
  end

  defp ts_from_meta(%{time: t}) when is_integer(t) do
    seconds = div(t, 1_000_000)
    micros = rem(t, 1_000_000)
    {date, {h, mi, se}} = :calendar.system_time_to_universal_time(seconds, :second)
    {date, {h, mi, se, div(micros, 1_000)}}
  end

  defp ts_from_meta(_) do
    {date, {h, mi, se}} = :calendar.universal_time()
    {date, {h, mi, se, 0}}
  end

  defp filter_metadata(meta, :all) do
    meta
    |> Map.drop(@drop_meta_default)
    |> Enum.to_list()
  end

  defp filter_metadata(meta, keys) when is_list(keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case meta do
        %{^key => val} -> [{key, val} | acc]
        _ -> acc
      end
    end)
  end

  # :logger has levels Logger doesn't: notice, critical, alert, emergency.
  # Map them onto Logger's nearest equivalent so Logger.Formatter doesn't
  # choke when rendering `$level`.
  defp downgrade_level(:notice), do: :info
  defp downgrade_level(:warning), do: :warning
  defp downgrade_level(:warn), do: :warning
  defp downgrade_level(:critical), do: :error
  defp downgrade_level(:alert), do: :error
  defp downgrade_level(:emergency), do: :error
  defp downgrade_level(level), do: level
end
