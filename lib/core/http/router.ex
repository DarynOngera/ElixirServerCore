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

  add_root_route()
  add_health_route()
  add_stats_route()
  add_job_routes()

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
