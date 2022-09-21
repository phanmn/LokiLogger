defmodule LokiLogger.HttpClient do
  use Tesla

  def new(%{auth: %{username: username, password: password}}) do
    middleware = [
      {Tesla.Middleware.BasicAuth, Map.merge(%{username: username, password: password})}
    ]

    Tesla.client(middleware)
  end

  def new(_) do
    Tesla.client([])
  end
end
