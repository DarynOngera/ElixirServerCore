# lib/core/http/router.ex
defmodule Core.HTTP.Router do
  use Plug.Router
  require Logger
  alias Core.Workers.JobQueue

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

  ## ============================================================
  ## Routes
  ## ============================================================

  # Root endpoint
  get "/" do
    send_resp(conn, 200, "Server is running")
  end

  # Health check
  get "/health" do
    worker_alive = Process.whereis(JobQueue) != nil
    status = if worker_alive, do: "OK", else: "DEGRADED"
    send_resp(conn, 200, status)
  end

  # Submit a new job
  post "/jobs" do
    case conn.body_params do
      %{"payload" => payload} ->
        {:ok, id} = JobQueue.submit(payload)
        
        response = Jason.encode!(%{
          message: "Job accepted",
          job_id: id
        })
        
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, response)
      
      _ ->
        error = Jason.encode!(%{error: "Missing 'payload' field"})
        
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, error)
    end
  end

  # Get all jobs
  get "/jobs" do
    jobs = JobQueue.all()
    response = Jason.encode!(jobs)
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response)
  end

  # Get a specific job by ID
  get "/jobs/:id" do
    id = String.to_integer(id)
    
    case JobQueue.get(id) do
      {:ok, job} ->
        response = Jason.encode!(job)
        
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, response)
      
      {:error, :not_found} ->
        error = Jason.encode!(%{error: "Job not found"})
        
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, error)
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
