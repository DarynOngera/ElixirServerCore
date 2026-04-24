# lib/core/http/router.ex
defmodule Core.HTTP.Router do
  @moduledoc """
  Default router implementation.
  This is used by the demo application.
  """
  use Plug.Router
  require Logger
  alias Core.Workers.JobQueue

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

  # Root endpoint
  get "/" do
    send_resp(conn, 200, "Server is running")
  end

  # Health check
  get "/health" do
    worker_alive = Process.whereis(JobQueue) != nil
    {status, code} = 
      if worker_alive, 
        do: {"OK", 200}, 
        else: {"DEGRADED", 503}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(%{status: status}))
  end

  get "/stats" do 
    stats = JobQueue.stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  # Submit a new job
  post "/jobs" do
    case conn.body_params do
      %{"payload" => payload}  when is_map(payload) ->
        opts = []
        opts = if conn.body_params["max_attempts"], do: Keyword.put(opts, :max_attempts, conn.body_params["max_attempts"]), else: opts

        {:ok, id} = JobQueue.submit(payload, opts)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{message: "Job accepted", job_id: id}))
 
      %{"payload" => _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "'payload' must be a JSON object"}))
 
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Missing 'payload' field"}))
    end
  end

  post "/jobs/schedule" do
    with %{"payload" => payload, "run_at" => run_at_str} <- conn.body_params,
         {:ok, run_at, _} <- DateTime.from_iso8601(run_at_str) do
      {:ok, id} = JobQueue.submit_at(payload, run_at)
 
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{message: "Job scheduled", job_id: id, run_at: run_at_str}))
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Required fields: payload (object), run_at (ISO8601)"}))
    end
  end

  get "/jobs" do
    try do 
    params = conn.query_params
 
    opts =
      []
      |> maybe_put(:status, params["status"] && String.to_existing_atom(params["status"]))
      |> maybe_put(:page, params["page"] && String.to_integer(params["page"]))
      |> maybe_put(:per_page, params["per_page"] && String.to_integer(params["per_page"]))
 
    jobs = JobQueue.all(opts)
 
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(jobs))
  rescue
    ArgumentError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "Invalid status filter. Valid values: queued, running, done, failed"}))
    end
  end
 
  get "/jobs/:id" do
    with {int_id, ""} <- Integer.parse(id),
         {:ok, job} <- JobQueue.get(int_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(job))
    else
      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Job ID must be an integer"}))
 
      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Job not found"}))
    end
  end
 
  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
