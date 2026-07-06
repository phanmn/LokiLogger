# LokiLogger

LokiLogger is an Elixir logger backend providing support for Logging to [Grafana Loki](https://github.com/grafana/loki).

[![Hex.pm Version](http://img.shields.io/hexpm/v/loki_logger.svg?style=flat)](https://hex.pm/packages/loki_logger)

## Features

* Elixir Logger formatting and metadata
* Multi-tenancy via `X-Scope-Org-Id`
* Snappy-compressed protobuf body
* Async, non-blocking delivery via Finch + Tesla
* Concurrent in-flight HTTP requests (bounded)
* Internal batch buffer with size- **and** time-based flushing
* Bounded overflow queue with drop-oldest policy under sustained backpressure
* Retry with exponential backoff + jitter on 429/5xx and network errors
* Two integration styles: legacy gen_event backend and modern `:logger` handler

## Installation

```elixir
def deps do
  [
    {:loki_logger, "~> 0.4.0"}
  ]
end
```

## Configuration

### Option A — gen_event backend (legacy Logger API)

```elixir
config :logger,
  backends: [LokiLogger]

config :logger, :loki_logger,
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: :all,
  max_buffer: 300,
  flush_interval_ms: 5_000,
  loki_labels: %{application: "my_app", node: node()},
  loki_host: "http://localhost:3100"
```

### Option B — `:logger` handler (recommended)

Same `config.exs` style as Option A, just **omit `LokiLogger` from
`backends`**. The library detects this and auto-installs the modern
`:logger` handler at boot:

```elixir
config :logger, :loki_logger,
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: :all,
  max_buffer: 300,
  flush_interval_ms: 5_000,
  loki_labels: %{application: "my_app", node: node()},
  loki_host: "http://localhost:3100"
```

The handler runs `log/2` in the **producing process**, so formatting
parallelizes naturally instead of being serialized through Logger's single
backend process.

`format` and `metadata` follow the same `Logger.Formatter` semantics as
the gen_event backend — copying your Option A config across produces
identical log lines.

#### How the library decides A vs. B

On boot, `LokiLogger.Application` looks at your config:

| `config :logger, :loki_logger` set? | `LokiLogger` in `:backends`? | Result |
| --- | --- | --- |
| no | — | nothing happens; library is dormant |
| yes | yes | Option A is active (gen_event); handler **not** installed |
| yes | no | Option B is active (handler auto-installed) |

So switching from A to B is just "drop `LokiLogger` from `backends`."

### Option B (alternative) — `:logger` handler, programmatic

If you'd rather install the handler yourself (e.g. after runtime secrets
are loaded):

```elixir
# In your Application.start/2:
LokiLogger.Handler.install()
```

Or bypass the Application env entirely with the raw OTP call:

```elixir
:ok = :logger.add_handler(:loki, LokiLogger.Handler, %{
  level: :info,
  config: %{
    loki_host: "http://localhost:3100",
    loki_labels: %{application: "my_app"},
    max_buffer: 300,
    flush_interval_ms: 5_000
  }
})
```

Both Option A and Option B share the same `LokiLogger.Exporter` internally
(Finch pool, batch buffer, retry/backoff, overflow queue).

## Configuration options

| Option | Default | Description |
| --- | --- | --- |
| `loki_host` | `"http://localhost:3100"` | Loki base URL |
| `loki_path` | `"/loki/api/v1/push"` | Push endpoint path |
| `loki_labels` | `%{application: "loki_logger_library"}` | Stream labels |
| `loki_scope_org_id` | — (omitted) | `X-Scope-OrgID` header (multitenancy). Sent only when set. Loki accepts any string; VictoriaLogs needs a numeric `AccountID` (e.g. `"0"`) |
| `basic_auth_user` / `basic_auth_password` | — | HTTP basic auth |
| `level` | `:info` | Minimum log level |
| `format` | `"$time $metadata[$level] $message\n"` | Logger format string (honored by both backends) |
| `metadata` | `:all` | Metadata keys to include |
| `max_buffer` | `300` | Flush after this many buffered events |
| `flush_interval_ms` | `5_000` | Periodic flush interval; `0` disables |
| `max_concurrency` | `pool_count` (4) | Concurrent in-flight pushes |
| `max_overflow` | `100` | Pending batches before drop-oldest kicks in |
| `max_retries` | `3` | Retries on 429 / 5xx / network errors |
| `retry_base_ms` | `200` | Base delay for exponential backoff |
| `pool_size` | `16` | Finch connections per pool |
| `pool_count` | `4` | Number of Finch pools |

## Behaviour under failure

* **Loki returns 2xx** — success.
* **Loki returns 429 or 5xx** — retried with exponential backoff + jitter
  (`retry_base_ms`, doubling each attempt). After `max_retries`, the batch is
  dropped and a line is written to stderr.
* **Loki returns 4xx (other than 429)** — dropped immediately (not retryable).
* **Network error** — retried as above.
* **Sustained backpressure** — when `max_concurrency` is saturated and the
  pending-batches queue hits `max_overflow`, the **oldest** queued batch is
  dropped to keep the newest data flowing. The drop counter is tracked on
  `LokiLogger.Exporter` state.

The producing process never blocks on Loki — submission to the Exporter is a
non-blocking cast.

## Testing against a fake Loki server

This repo ships an in-process HTTP server (`LokiLogger.FakeLokiServer`) that
mimics Loki's `/loki/api/v1/push` endpoint — it decodes the snappy-compressed
protobuf body and forwards `Logproto.PushRequest` structs to a subscribed
test pid, so you can assert on what would have been sent.

Example (compile only in test, requires `:plug` and `:bandit`):

```elixir
defmodule MyApp.LokiLoggerTest do
  use ExUnit.Case, async: false

  alias LokiLogger.FakeLokiServer

  setup do
    Logger.remove_backend(LokiLogger)
    FakeLokiServer.reset()
    {:ok, server, url} = FakeLokiServer.start()
    FakeLokiServer.listen_with(self())

    Application.put_env(:logger, :loki_logger,
      loki_host: url,
      loki_labels: %{app: "test"},
      max_buffer: 1,
      flush_interval_ms: 0
    )

    LokiLogger.start_pipeline()
    on_exit(fn -> Process.exit(server, :normal) end)
    :ok
  end

  test "ships a line to Loki" do
    LokiLogger.Exporter.log_event({1_000_000_000, "hello loki"})

    assert_receive {:loki_push, {:ok, push}, _headers}, 1_000
    [stream] = push.streams
    assert [%{line: "hello loki"}] = stream.entries
  end

  test "retries 5xx then succeeds" do
    FakeLokiServer.queue_response(503, "boom")
    FakeLokiServer.queue_response(204, "")

    LokiLogger.Exporter.log_event({1_000_000_000, "retry me"})

    assert_receive {:loki_push, _, _}, 500
    assert_receive {:loki_push, _, _}, 500
  end
end
```

See `test/loki_logger_integration_test.exs` in this repo for the full set of
patterns (batching, retry, header forwarding, time-based flush).

## Protobuf regeneration

Only needed when modifying the proto files:

```shell
protoc --proto_path=./lib/proto --elixir_out=./lib lib/proto/loki.proto
```

## License

Loki Logger is copyright (c) 2019 Ward Bekker.

Released under the Apache v2.0 License — see [LICENSE](LICENSE).
