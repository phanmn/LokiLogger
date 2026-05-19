defmodule LokiLogger.MixProject do
  use Mix.Project

  def project do
    [
      app: :loki_logger,
      version: "0.5.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Loki Logger",
      source_url: "https://github.com/wardbekker/LokiLogger.git"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LokiLogger.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4.0"},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:benchee, "~> 1.1.0", only: :test},
      {:tesla, "~> 1.11"},
      {:finch, "~> 0.17"},
      {:protobuf, "~> 0.15"},
      {:snappyer, git: "https://github.com/phanmn/snappyer.git", branch: "master"},
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test}
    ]
  end

  defp description() do
    "Elixir Logger Backend for Grafana Loki"
  end

  defp package() do
    [
      name: "loki_logger",
      # These are the default files included in the package
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/wardbekker/LokiLogger.git"}
    ]
  end
end
