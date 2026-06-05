defmodule ElixirServerCore.Application do
  @moduledoc """
  Main application supervisor. Starts in all Mix environments.
  Forks should replace Core.HTTP.Router with their own router module,
  and optionally swap Core.Workers.Worker for a domain-specific worker.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4000") |> String.to_integer()
    store = Application.get_env(:elixir_server_core, :job_store, Core.JobStore.Memory)
    store_opts = Application.get_env(:elixir_server_core, :job_store_opts, [])

    children = [
      {Core.Workers.JobQueue, store: store, store_opts: store_opts},
      Core.Workers.WorkerPool,
      {Plug.Cowboy,
       scheme: :http, plug: Core.HTTP.Router, options: [port: port, ip: {0, 0, 0, 0}]}
    ]

    Logger.info("Starting Elixir Server Core on port #{port}")
    Logger.info("http://localhost:#{port}")

    opts = [strategy: :one_for_one, name: ElixirServerCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
