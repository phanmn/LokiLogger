defmodule LokiLogger.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # AppSupervisor is always started, even when LokiLogger isn't configured,
    # so that `LokiLogger.start_pipeline/1` can later add the pipeline as a
    # permanent child if config arrives at runtime.
    result =
      Supervisor.start_link([],
        strategy: :one_for_one,
        name: LokiLogger.AppSupervisor,
        max_restarts: 100,
        max_seconds: 60
      )

    if loki_logger_configured?() do
      # Start the pipeline supervisor as a permanent child of AppSupervisor
      # so OTP will keep restarting it if it crashes.
      _ = LokiLogger.start_pipeline()

      if not gen_event_backend_configured?() do
        case LokiLogger.Handler.install() do
          :ok ->
            :ok

          # Already installed (e.g. application restart). Stay idempotent.
          {:error, {:already_exist, _}} ->
            :ok

          {:error, {:already_exists, _}} ->
            :ok

          error ->
            raise "LokiLogger handler install failed: #{inspect(error)}"
        end
      end
    end

    result
  end

  defp loki_logger_configured? do
    case Application.get_env(:logger, :loki_logger) do
      config when is_list(config) and config != [] -> true
      _ -> false
    end
  end

  defp gen_event_backend_configured? do
    :logger
    |> Application.get_env(:backends, [])
    |> Enum.any?(fn
      LokiLogger -> true
      {LokiLogger, _id} -> true
      _ -> false
    end)
  end
end
