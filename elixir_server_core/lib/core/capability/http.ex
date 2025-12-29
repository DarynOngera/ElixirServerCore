defmodule Core.Capability.HTTP do
  @moduledoc """
  HTTP server capability with configurable router.
  Can be used standalone or as part of a supervision tree.
  """
  
  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4000)
    router = Keyword.get(opts, :router, Core.HTTP.BaseRouter)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})
    
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: router,
      options: [port: port, ip: ip]
    )
  end
end
