defmodule Core.Capability.WorkQueue do
  use Supervisor
  alias Core.Workers.JobQueue

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {JobQueue, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

