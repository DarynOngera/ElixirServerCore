defmodule ElixirServerCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Core.Workers.JobQueue
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: ElixirServerCore.Supervisor
    )
  end
end

