import Config

config :tesla, adapter: {Tesla.Adapter.Hackney, [recv_timeout: 30_000]}

http_client = fn %{method: :post, url: url, data: data, headers: headers} ->
  url
  |> Tesla.post(data, headers: headers)
end

config :logger, :loki_logger, http_client: http_client
