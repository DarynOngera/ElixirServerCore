defmodule ElixirServerCore.Application do
  @moduledoc """
  Demo application showing how to use the framework.
  This only runs when starting the project directly (not as a dependency).
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4000") |> String.to_integer()

    children = [
      # Using the capability modules
      {Core.Capability.WorkQueue, []},
      {Core.Capability.HTTP, port: port, router: Core.HTTP.Router}
    ]
    
    Logger.info("Starting Elixir Server Core (Demo Mode)")
    Logger.info("Server running on http://localhost:#{port}")
    
    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: ElixirServerCore.Supervisor
    )
  end
end
