defmodule ElixirServerCore.Application do
  @moduledoc """
  Main application supervisor. Configurable via `Application.get_env(:servcore, ...)`.

  ## Configuration options

      config :servcore,
        router: MyApp.Router,           # default: Core.HTTP.Router
        port: 4000,                     # default: env PORT or 4000
        ip: {0, 0, 0, 0},              # default: {0,0,0,0}
        worker: Core.Workers.Worker,  # default: Core.Workers.Worker
        worker_pool_size: 8,            # default: CPU cores
        job_store: Core.JobStore.SQLite, # default: Core.JobStore.Memory
        job_store_opts: [database: "priv/jobs.db"],
        start_http: true,               # default: true
        start_workers: true             # default: true

  Set `start_http: false` to manage Plug.Cowboy yourself (e.g. in a Phoenix app).
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = get_port()
    router = get_router()
    ip = get_ip()
    worker = get_worker()
    pool_size = get_pool_size()
    store = get_job_store()
    store_opts = get_job_store_opts()
    start_http? = Application.get_env(:servcore, :start_http, true)
    start_workers? = Application.get_env(:servcore, :start_workers, true)

    children = [
      {Core.Workers.JobQueue, store: store, store_opts: store_opts}
    ]

    children =
      if start_workers? do
        [{Core.Workers.WorkerPool, worker: worker, size: pool_size} | children]
      else
        children
      end

    children =
      if start_http? do
        http_spec =
          {Plug.Cowboy, scheme: :http, plug: router, options: [port: port, ip: ip]}

        [http_spec | children]
      else
        children
      end

    if start_http? do
      Logger.info("Starting ServCore on port #{port}")
      Logger.info("http://localhost:#{port}")
    end

    opts = [strategy: :one_for_one, name: ElixirServerCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # --- Config helpers ---

  defp get_port do
    System.get_env("PORT", "4000") |> String.to_integer()
  end

  defp get_router do
    Application.get_env(:servcore, :router, Core.HTTP.Router)
  end

  defp get_ip do
    Application.get_env(:servcore, :ip, {0, 0, 0, 0})
  end

  defp get_worker do
    Application.get_env(:servcore, :worker, Core.Workers.Worker)
  end

  defp get_pool_size do
    Application.get_env(:servcore, :worker_pool_size, System.schedulers_online())
  end

  defp get_job_store do
    Application.get_env(:servcore, :job_store, Core.JobStore.Memory)
  end

  defp get_job_store_opts do
    Application.get_env(:servcore, :job_store_opts, [])
  end
end
