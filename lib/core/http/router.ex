# lib/core/http/router.ex
defmodule Core.HTTP.Router do
  @moduledoc """
  Default router implementation.
  This is used by the demo application.
  """
  use Plug.Router
  require Logger

  plug(Plug.Logger, log: :info)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(Plug.Telemetry, event_prefix: [:server, :http])
  plug(:dispatch)

  import Core.HTTP.BaseRouter
  alias Core.HTTP.Handlers

  add_root_route()
  add_health_route()
  add_stats_route()

  post "/jobs" do
    Handlers.create_job(conn)
  end

  post "/jobs/schedule" do
    Handlers.schedule_job(conn)
  end

  get "/jobs" do
    Handlers.list_jobs(conn)
  end

  get "/jobs/:id" do
    Handlers.get_job(conn, id)
  end

  match _ do
    Handlers.send_json(conn, 404, %{error: "Not found"})
  end
end
