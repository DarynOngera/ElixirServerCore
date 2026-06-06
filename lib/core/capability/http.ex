defmodule Core.Capability.HTTP do
  @moduledoc """
  HTTP server capability with a configurable router module.

  ## Usage in a supervision tree

      children = [
        {Core.Capability.HTTP, port: 4000, router: MyApp.Router}
      ]

  ## Options

    - `:port`   — TCP port to listen on (default: 4000)
    - `:router` — Plug module to route requests (default: Core.HTTP.Router)
    - `:ip`     — IP tuple to bind (default: {0,0,0,0} = all interfaces)
  """
  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4000)
    router = Keyword.get(opts, :router, Core.HTTP.BaseRouter)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})

    Bandit.child_spec(
      plug: router,
      scheme: :http,
      port: port,
      ip: ip,
      http_2_options: [enabled: true]
    )
  end
end
