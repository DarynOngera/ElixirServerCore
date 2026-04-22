defmodule Core.HTTP.BaseRouter do
  @moduledoc """
  Helper functions and documentation for creating custom routers.
  
  ## Usage
  
  To create a custom router that includes base functionality:
  
      defmodule MyCustomRouter do
        use Plug.Router
        require Logger
        alias Core.Workers.JobQueue
  
        plug Plug.Logger, log: :info
        plug :match
        plug Plug.Parsers, parsers: [:json], json_decoder: Jason
        plug Plug.Telemetry, event_prefix: [:server, :http]
        plug :dispatch
  
        # Include base job routes
        import Core.HTTP.BaseRouter
        add_job_routes()
  
        # Add your custom routes
        get "/custom" do
          send_resp(conn, 200, "Custom route")
        end
  
        match _ do
          send_resp(conn, 404, "Not Found")
        end
      end
  
  Or simply copy the route definitions from Core.HTTP.Router.
  """

  @doc """
  Returns the standard Plug setup for a router.
  Use this as reference when creating your own router.
  """
  def standard_plugs do
    quote do
      plug Plug.Logger, log: :info
      plug :match
      plug Plug.Parsers, parsers: [:json], json_decoder: Jason
      plug Plug.Telemetry, event_prefix: [:server, :http]
      plug :dispatch
    end
  end

  @doc """
  Adds job management routes to a router.
  
  This macro injects POST /jobs, GET /jobs, and GET /jobs/:id routes.
  Call this within a router module that has already used Plug.Router.
  """
  defmacro add_job_routes do
    quote do
      # Submit a new job
      post "/jobs" do
        case var!(conn).body_params do
          %{"payload" => payload} ->
            {:ok, id} = Core.Workers.JobQueue.submit(payload)
            
            response = Jason.encode!(%{
              message: "Job accepted",
              job_id: id
            })
            
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(202, response)
          
          _ ->
            error = Jason.encode!(%{error: "Missing 'payload' field"})
            
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(400, error)
        end
      end

      # Get all jobs
      get "/jobs" do
        jobs = Core.Workers.JobQueue.all()
        response = Jason.encode!(jobs)
        
        var!(conn)
        |> put_resp_content_type("application/json")
        |> send_resp(200, response)
      end

      # Get a specific job by ID
      get "/jobs/:id" do
        id = String.to_integer(var!(id))
        
        case Core.Workers.JobQueue.get(id) do
          {:ok, job} ->
            response = Jason.encode!(job)
            
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(200, response)
          
          {:error, :not_found} ->
            error = Jason.encode!(%{error: "Job not found"})
            
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(404, error)
        end
      end
    end
  end

  @doc """
  Adds health check route to a router.
  """
  defmacro add_health_route do
    quote do
      get "/health" do
        worker_alive = Process.whereis(Core.Workers.JobQueue) != nil
        status = if worker_alive, do: "OK", else: "DEGRADED"
        send_resp(var!(conn), 200, status)
      end
    end
  end

  @doc """
  Adds root route to a router.
  """
  defmacro add_root_route do
    quote do
      get "/" do
        send_resp(var!(conn), 200, "Server is running")
      end
    end
  end
end
