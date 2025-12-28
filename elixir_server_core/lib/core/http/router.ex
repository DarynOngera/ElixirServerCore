# lib/core/http/router.ex
defmodule Core.HTTP.Router do
  use Plug.Router
  require Logger
  alias Core.Workers.JobQueue

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

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
    {:ok, body, _} = Plug.Conn.read_body(conn)
    {:ok, id} = JobQueue.submit(%{payload: body})
    send_resp(conn, 202, "Job accepted: #{id}")
  end

  # List all jobs
  get "/jobs" do
    jobs = JobQueue.all()
    send_resp(conn, 200, Jason.encode!(jobs))
  end

  # Mark job running
  post "/jobs/:id/run" do
    id = String.to_integer(id)
    case JobQueue.mark_running(id) do
      :ok -> send_resp(conn, 200, "Job #{id} marked running")
      {:error, :not_found} -> send_resp(conn, 404, "Job not found")
    end
  end

  # Mark job done
  post "/jobs/:id/done" do
    id = String.to_integer(id)
    {:ok, body, _} = Plug.Conn.read_body(conn)
    result = Jason.decode!(body)
    
    case JobQueue.mark_done(id, result) do
      :ok -> send_resp(conn, 200, "Job #{id} marked done")
      {:error, :not_found} -> send_resp(conn, 404, "Job not found")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end

