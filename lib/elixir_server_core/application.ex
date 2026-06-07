defmodule ElixirServerCore.Application do
  @moduledoc """
  Main application supervisor. Configurable via `Application.get_env(:servcore, ...)`.

  ## Configuration options (single pipeline, backward compatible)

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

  ## Configuration options (multiple pipelines)

      config :servcore,
        router: MyApp.Router,
        port: 4000,
        start_http: true,
        pipelines: [
          [
            queue: Core.Workers.JobQueue,
            queue_name: Core.Workers.JobQueue,
            pool: Core.Workers.WorkerPool,
            worker: Core.Workers.Worker,
            pool_size: 4,
            job_store: Core.JobStore.SQLite,
            job_store_opts: [database: "priv/jobs.db"]
          ],
          [
            queue: Core.Workers.JobQueue,
            queue_name: MyApp.MediaQueue,
            pool: Core.Workers.WorkerPool,
            pool_name: MyApp.MediaPool,
            worker: MyApp.MediaWorker,
            pool_size: 2,
            job_store: Core.JobStore.SQLite,
            job_store_opts: [database: "priv/media_jobs.db"]
          ]
        ]

  Set `start_http: false` to manage the HTTP server yourself (e.g. in a Phoenix app).
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    start_http? = Application.get_env(:servcore, :start_http, true)

    children = build_pipeline_children()

    children =
      if start_http? do
        port = get_port()
        router = get_router()
        ip = get_ip()

        http_spec =
          {Bandit,
           plug: router, scheme: :http, port: port, ip: ip, http_2_options: [enabled: true]}

        [http_spec | children]
      else
        children
      end

    if start_http? do
      Logger.info("Starting ServCore on port #{get_port()}")
      Logger.info("http://localhost:#{get_port()}")
    end

    opts = [strategy: :one_for_one, name: ElixirServerCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # --- Pipeline builder ---

  defp build_pipeline_children do
    case Application.get_env(:servcore, :pipelines) do
      nil ->
        build_single_pipeline()

      pipelines when is_list(pipelines) ->
        Enum.flat_map(pipelines, &build_pipeline/1)
    end
  end

  defp build_single_pipeline do
    worker = get_worker()
    pool_size = get_pool_size()
    store = get_job_store()
    store_opts = get_job_store_opts()
    max_age_days = Application.get_env(:servcore, :max_age_days, 7)
    start_workers? = Application.get_env(:servcore, :start_workers, true)

    queue_spec =
      {Core.Workers.JobQueue,
       name: Core.Workers.JobQueue,
       pool: Core.Workers.WorkerPool,
       store: store,
       store_opts: store_opts,
       max_age_days: max_age_days}

    pool_spec =
      {Core.Workers.WorkerPool,
       name: Core.Workers.WorkerPool,
       worker: worker,
       size: pool_size,
       queue: Core.Workers.JobQueue}

    if start_workers? do
      [pool_spec, queue_spec]
    else
      [queue_spec]
    end
  end

  defp build_pipeline(pipeline) when is_list(pipeline) do
    queue_module = Keyword.get(pipeline, :queue, Core.Workers.JobQueue)
    queue_name = Keyword.get(pipeline, :queue_name, queue_module)
    pool_module = Keyword.get(pipeline, :pool, Core.Workers.WorkerPool)
    pool_name = Keyword.get(pipeline, :pool_name, pool_module)
    worker = Keyword.get(pipeline, :worker, Core.Workers.Worker)
    pool_size = Keyword.get(pipeline, :pool_size, System.schedulers_online())
    store = Keyword.get(pipeline, :job_store, Core.JobStore.Memory)
    store_opts = Keyword.get(pipeline, :job_store_opts, [])
    max_age_days = Keyword.get(pipeline, :max_age_days, 7)
    start_workers? = Keyword.get(pipeline, :start_workers, true)

    queue_spec =
      {queue_module,
       name: queue_name,
       pool: pool_name,
       store: store,
       store_opts: store_opts,
       max_age_days: max_age_days}

    pool_spec =
      {pool_module,
       name: pool_name,
       worker: worker,
       size: pool_size,
       queue: queue_name}

    if start_workers? do
      [pool_spec, queue_spec]
    else
      [queue_spec]
    end
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
