defmodule Core.ServerTemplate do
  @moduledoc """
  Minimal supervision template. Copy this as your Application module
  when forking the server. Swap router and worker_module for your own.

  This template shows a single named queue + pool. For multiple pipelines,
  see `ElixirServerCore.Application` and the `:pipelines` config key.
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4000") |> String.to_integer()
    router = Application.get_env(:servcore, :router, Core.HTTP.Router)
    worker_module = Application.get_env(:servcore, :worker, Core.Workers.Worker)

    children = [
      {Core.Workers.JobQueue, name: Core.Workers.JobQueue, pool: Core.Workers.WorkerPool},
      {Core.Workers.WorkerPool,
       name: Core.Workers.WorkerPool, worker: worker_module, queue: Core.Workers.JobQueue},
      Core.Capability.HTTP.child_spec(port: port, router: router)
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
