defmodule Core.HTTP.Handlers do
  @moduledoc """
  Plain functions for handling HTTP requests.

  These functions can be called directly from router definitions,
  giving forking developers full control over which routes to mount
  and how to wrap them (e.g. authentication, logging, rate limiting).
  """

  import Plug.Conn

  alias Core.Workers.JobQueue

  @doc """
  Renders a JSON response with the given HTTP status code.
  """
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc """
  Checks health of the given queues and returns a tuple of `{status_code, body_map}`.
  """
  def health_check(queues) do
    statuses =
      for queue <- queues do
        alive = Process.whereis(queue) != nil
        {queue, alive}
      end

    all_alive = Enum.all?(statuses, fn {_, alive} -> alive end)
    {status, code} = if all_alive, do: {"OK", 200}, else: {"DEGRADED", 503}

    body = %{
      status: status,
      queues: Map.new(statuses, fn {q, alive} -> {inspect(q), alive} end)
    }

    {code, body}
  end

  @doc """
  Aggregates stats across the given queues and returns a stats map.
  """
  def stats_response(queues) do
    Enum.reduce(queues, %{queued: 0, running: 0, done: 0, failed: 0, total: 0}, fn queue, acc ->
      case Process.whereis(queue) do
        nil ->
          acc

        _ ->
          s = JobQueue.stats(queue)

          %{
            queued: acc.queued + s.queued,
            running: acc.running + s.running,
            done: acc.done + s.done,
            failed: acc.failed + s.failed,
            total: acc.total + s.total
          }
      end
    end)
  end

  @doc """
  Handles POST /jobs — submits a job to the given queue.
  """
  def create_job(conn, queue \\ JobQueue) do
    case conn.body_params do
      %{"payload" => payload} when is_map(payload) ->
        opts =
          if conn.body_params["max_attempts"],
            do: [max_attempts: conn.body_params["max_attempts"]],
            else: []

        {:ok, id} = JobQueue.submit(queue, payload, opts)
        send_json(conn, 202, %{message: "Job accepted", job_id: id})

      %{"payload" => _} ->
        send_json(conn, 400, %{error: "'payload' must be a JSON object"})

      _ ->
        send_json(conn, 400, %{error: "Missing 'payload' field"})
    end
  end

  @doc """
  Handles POST /jobs/schedule — schedules a job for a future time.
  """
  def schedule_job(conn, queue \\ JobQueue) do
    payload = conn.body_params["payload"]
    run_at_str = conn.body_params["run_at"]

    if is_map(payload) and is_binary(run_at_str) do
      case DateTime.from_iso8601(run_at_str) do
        {:ok, run_at, _} ->
          {:ok, id} = JobQueue.submit_at(queue, payload, run_at)

          send_json(conn, 202, %{
            message: "Job scheduled",
            job_id: id,
            run_at: run_at_str
          })

        _ ->
          send_json(conn, 400, %{
            error: "Required: payload (object), run_at (ISO8601 string)"
          })
      end
    else
      send_json(conn, 400, %{
        error: "Required: payload (object), run_at (ISO8601 string)"
      })
    end
  end

  @doc """
  Handles GET /jobs — lists jobs with optional filtering and pagination.
  """
  def list_jobs(conn, queue \\ JobQueue) do
    try do
      params = conn.query_params

      opts =
        []
        |> maybe_put(:status, parse_status(params["status"]))
        |> maybe_put(:page, parse_integer(params["page"]))
        |> maybe_put(:per_page, parse_integer(params["per_page"]))

      jobs = JobQueue.all(queue, opts)
      send_json(conn, 200, jobs)
    rescue
      ArgumentError ->
        send_json(conn, 400, %{
          error: "Invalid status. Valid: queued, running, done, failed"
        })
    end
  end

  @doc """
  Handles GET /jobs/:id — fetches a single job by ID.
  """
  def get_job(conn, id, queue \\ JobQueue) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case JobQueue.get(queue, int_id) do
          {:ok, job} ->
            send_json(conn, 200, job)

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "Job not found"})
        end

      _ ->
        send_json(conn, 400, %{error: "Job ID must be an integer"})
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_status(nil), do: nil
  defp parse_status(s), do: String.to_existing_atom(s)

  defp parse_integer(nil), do: nil
  defp parse_integer(p), do: String.to_integer(p)
end
