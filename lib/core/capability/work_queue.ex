defmodule Core.Capability.WorkQueue do
  @moduledoc """
  Work queue capability with configurable worker module.

  Starts a named `JobQueue` and a `WorkerPool` that polls it.

  ## Options

    * `:name` – supervisor name (default: `Core.Capability.WorkQueue`)
    * `:queue` – `JobQueue` name (default: `Core.Workers.JobQueue`)
    * `:worker` – worker module (default: `Core.Workers.Worker`)

  ## Example

      {Core.Capability.WorkQueue,
        name: MyApp.WorkQueue,
        queue: MyApp.Queue,
        worker: MyApp.Worker}
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    worker_module = Keyword.get(opts, :worker, Core.Workers.Worker)
    queue_name = Keyword.get(opts, :queue, Core.Workers.JobQueue)
    pool_name = Keyword.get(opts, :pool, Core.Workers.WorkerPool)

    children = [
      {Core.Workers.JobQueue, name: queue_name, pool: pool_name},
      {Core.Workers.WorkerPool, name: pool_name, worker: worker_module, queue: queue_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
