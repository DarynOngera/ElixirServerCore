defmodule Core.Workers.WorkerPool do
  @moduledoc """
  Supervisor that manages a pool of concurrent workers.

  Pool size defaults to the number of online schedulers (CPU cores).
  Configure via the `:worker_pool_size` application env:

      config :servcore, worker_pool_size: 4

  Or pass at startup:

      {Core.Workers.WorkerPool, name: MyApp.Pool, worker: MyApp.Worker, size: 4, queue: MyApp.Queue}
  """
  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    size =
      Keyword.get(opts, :size) ||
        Application.get_env(:servcore, :worker_pool_size) ||
        System.schedulers_online()

    worker_module = Keyword.get(opts, :worker, Core.Workers.Worker)
    queue_name = Keyword.get(opts, :queue, Core.Workers.JobQueue)
    pool_name = Keyword.get(opts, :name, __MODULE__)

    Code.ensure_loaded!(worker_module)

    unless function_exported?(worker_module, :start_link, 1) do
      raise ArgumentError,
            "#{inspect(worker_module)} must implement start_link/1 accepting [id: integer()]"
    end

    Logger.info("WorkerPool #{inspect(pool_name)} starting #{size} workers (module: #{worker_module})")

    children =
      for i <- 1..size do
        worker_opts = [id: i, queue: queue_name, pool: pool_name]

        Supervisor.child_spec(
          {worker_module, worker_opts},
          id: {worker_module, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
