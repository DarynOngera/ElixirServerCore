defmodule ElixirServerCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_server_core,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
       {:plug_cowboy, "~> 2.7"}, # HTTP server
       {:jason, "~> 1.4"}
    ]
  end
end
