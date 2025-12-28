defmodule Core.Application do 
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      Core.Workers.JobQueue
    ]
    
    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

