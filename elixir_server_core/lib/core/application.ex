defmodule Core.Application do 
  use Application
  require Logger

  def start(_type, _args) do
    children = []
    
    opts = [strategy: :one_for_one, name: Core.Supervisor]
  case Supervisor.start_link(children, opts) do 
      {:ok, pid} ->
        Logger.info("")
        {:ok, pid}
      error ->
        error
  end
end

