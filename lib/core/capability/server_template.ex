defmodule Core.ServerTemplate do
  @moduledoc """
  Minimal supervision template. Copy this as your Application module
  when forking the server. Swap router and worker_module for your own.
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4000") |> String.to_integer()
    router = Application.get_env(:servcore, :router, Core.HTTP.Router)
    worker_module = Application.get_env(:servcore, :worker, Core.Workers.Worker)

    children = [
      Core.Workers.JobQueue,
      {Core.Workers.WorkerPool, worker: worker_module},
      Core.Capability.HTTP.child_spec(port: port, router: router)
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
