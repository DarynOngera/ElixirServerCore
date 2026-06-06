defmodule ElixirServerCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :servcore,
      version: "0.2.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ServCore",
      description:
        "A minimal, forkable Elixir server with HTTP routing, background job queueing, and pluggable persistence.",
      source_url: "https://github.com/DarynOngera/ServCore",
      homepage_url: "https://github.com/DarynOngera/ServCore",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "FORKING.md", "ENDPOINT_TEST.md"],
        groups_for_modules: [
          "HTTP Layer": [Core.HTTP.Router, Core.HTTP.BaseRouter],
          "Job System": [
            Core.Workers.Job,
            Core.Workers.JobQueue,
            Core.Workers.Worker,
            Core.Workers.WorkerPool
          ],
          Capabilities: [Core.Capability.HTTP, Core.Capability.WorkQueue, Core.ServerTemplate],
          Telemetry: [Core.Telemetry.Events, Core.Telemetry.Metrics, Core.Capability.Metrics]
        ]
      ]
    ]
  end

  defp package do
    [
      name: "servcore",
      files: ["lib", "mix.exs", "README.md", "LICENSE*"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/DarynOngera/ServCore",
        "Docs" => "https://hexdocs.pm/servcore"
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirServerCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      # HTTP server
      {:bandit, "~> 1.8"},
      {:jason, "~> 1.4"},
      # Optional: uncomment for Prometheus integration
      # {:telemetry_metrics_prometheus, "~> 1.1"},
      # Optional: uncomment for SQLite persistence
      {:exqlite, "~> 0.29", optional: true},
      # Optional: uncomment for PostgreSQL persistence
      # {:postgrex, "~> 0.17"},
      # {:ecto_sql, "~> 3.10"},
      # Test/dev only 
      {:stream_data, "~> 0.6", only: [:test, :dev]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
