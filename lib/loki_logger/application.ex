defmodule LokiLogger.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_install_handler()
    Supervisor.start_link([], strategy: :one_for_one, name: LokiLogger.AppSupervisor)
  end

  # Auto-install the :logger handler when LokiLogger config exists but the
  # gen_event backend isn't already wired up — the user has opted into
  # LokiLogger but not into the legacy backend, so use the modern path.
  defp maybe_install_handler do
    with config when is_list(config) and config != [] <-
           Application.get_env(:logger, :loki_logger),
         false <- gen_event_backend_configured?() do
      case LokiLogger.Handler.install() do
        :ok ->
          :ok

        error ->
          # Boot fails loudly on misconfiguration rather than silently
          # swallowing — easier to debug than a missing log handler.
          raise "LokiLogger handler install failed: #{inspect(error)}"
      end
    else
      _ -> :ok
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
