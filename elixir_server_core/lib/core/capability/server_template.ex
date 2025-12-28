defmodule Core.ServerTemplate do
  use Application

  def start(_type, _args) do
    children = [
      Core.Capability.HTTP.child_spec(4000),
      {Core.Capability.WorkQueue, []}
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

