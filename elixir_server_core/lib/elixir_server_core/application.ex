defmodule ElixirServerCore.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = 4000

    children = [
      {Plug.Cowboy, scheme: :http, plug: Core.HTTP.Router, options: [port: port, ip: {0,0,0,0}]},
      Core.Workers.JobQueue,
      Core.Workers.Worker
    ]
    Logger.info("Starting server on port #{port}")
    Logger.info("http://localhost:4000")
    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: ElixirServerCore.Supervisor
    )
  end
end

