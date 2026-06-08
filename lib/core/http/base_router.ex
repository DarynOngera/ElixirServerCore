defmodule Core.HTTP.BaseRouter do
  @moduledoc """
  Composable macros for building custom routers on top of Elixir Server Core.

  ## Usage

      defmodule MyApp.Router do
        use Plug.Router
        require Logger

        plug Plug.Logger, log: :info
        plug :match
        plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
        plug Plug.Telemetry, event_prefix: [:server, :http]
        plug :dispatch

        import Core.HTTP.BaseRouter
        alias Core.HTTP.Handlers

        add_root_route()
        add_health_route([MyApp.Queue1, MyApp.Queue2])
        add_stats_route([MyApp.Queue1, MyApp.Queue2])

        # Job routes are explicit so you can wrap or skip individual ones
        post "/jobs",        do: Handlers.create_job(conn, MyApp.Queue1)
        post "/jobs/schedule", do: Handlers.schedule_job(conn, MyApp.Queue1)
        get "/jobs",         do: Handlers.list_jobs(conn, MyApp.Queue1)
        get "/jobs/:id",     do: Handlers.get_job(conn, id, MyApp.Queue1)

        get "/my-domain" do
          send_resp(conn, 200, "custom")
        end

        match _ do
          send_resp(conn, 404, "Not Found")
        end
      end
  """

  @doc """
  Injects a GET / route returning a plain-text status message.
  """
  defmacro add_root_route do
    quote do
      get "/" do
        send_resp(var!(conn), 200, "Server is running")
      end
    end
  end

  @doc """
  Injects GET /health — returns JSON {status: "OK", queues: %{...}} or {status: "DEGRADED", queues: %{...}} (503).
  Checks every queue in the provided list.
  """
  defmacro add_health_route(queues \\ [Core.Workers.JobQueue]) do
    quote do
      get "/health" do
        {code, body} = Core.HTTP.Handlers.health_check(unquote(queues))
        Core.HTTP.Handlers.send_json(var!(conn), code, body)
      end
    end
  end

  @doc """
  Injects GET /stats — returns aggregate job counts across all provided queues.
  """
  defmacro add_stats_route(queues \\ [Core.Workers.JobQueue]) do
    quote do
      get "/stats" do
        stats = Core.HTTP.Handlers.stats_response(unquote(queues))
        Core.HTTP.Handlers.send_json(var!(conn), 200, stats)
      end
    end
  end
end
