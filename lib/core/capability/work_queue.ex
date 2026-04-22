defmodule Core.Capability.WorkQueue do
  @moduledoc """
  Work queue capability with configurable worker module.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    worker_module = Keyword.get(opts, :worker, Core.Workers.Worker)
    
    children = [
      Core.Workers.JobQueue,
      {worker_module, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
