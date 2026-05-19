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
| `loki_scope_org_id` | `"fake"` | `X-Scope-OrgID` header (multitenancy) |
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

## Protobuf regeneration

Only needed when modifying the proto files:

```shell
protoc --proto_path=./lib/proto --elixir_out=./lib lib/proto/loki.proto
```

## License

Loki Logger is copyright (c) 2019 Ward Bekker.

Released under the Apache v2.0 License — see [LICENSE](LICENSE).
