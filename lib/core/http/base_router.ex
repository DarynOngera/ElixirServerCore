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

        add_root_route()
        add_health_route([MyApp.Queue1, MyApp.Queue2])
        add_stats_route([MyApp.Queue1, MyApp.Queue2])
        add_job_routes(queue: MyApp.Queue1, path_prefix: "/jobs")
        add_job_routes(queue: MyApp.Queue2, path_prefix: "/media_jobs")

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
        statuses =
          for queue <- unquote(queues) do
            alive = Process.whereis(queue) != nil
            {queue, alive}
          end

        all_alive = Enum.all?(statuses, fn {_, alive} -> alive end)
        {status, code} = if all_alive, do: {"OK", 200}, else: {"DEGRADED", 503}

        body = %{
          status: status,
          queues: Map.new(statuses, fn {q, alive} -> {inspect(q), alive} end)
        }

        var!(conn)
        |> put_resp_content_type("application/json")
        |> send_resp(code, Jason.encode!(body))
      end
    end
  end

  @doc """
  Injects GET /stats — returns aggregate job counts across all provided queues.
  """
  defmacro add_stats_route(queues \\ [Core.Workers.JobQueue]) do
    quote do
      get "/stats" do
        stats =
          Enum.reduce(unquote(queues), %{queued: 0, running: 0, done: 0, failed: 0, total: 0}, fn queue, acc ->
            case Process.whereis(queue) do
              nil ->
                acc

              _ ->
                s = Core.Workers.JobQueue.stats(queue)

                %{
                  queued: acc.queued + s.queued,
                  running: acc.running + s.running,
                  done: acc.done + s.done,
                  failed: acc.failed + s.failed,
                  total: acc.total + s.total
                }
            end
          end)

        var!(conn)
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(stats))
      end
    end
  end

  @doc """
  Conditionally put a key into a keyword list if the value is not nil.
  """
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Injects POST /jobs, POST /jobs/schedule, GET /jobs, GET /jobs/:id.

  Accepts options:
    - `:queue` — the JobQueue module/name to use (default: `Core.Workers.JobQueue`)
    - `:path_prefix` — mount point for the routes (default: `"/jobs"`)

  GET /jobs supports query params:
    - status=queued|running|done|failed
    - page=N  (default 1)
    - per_page=N (default 50, max 200)
  """
  defmacro add_job_routes(opts \\ []) do
    queue = Keyword.get(opts, :queue, Core.Workers.JobQueue)
    prefix = Keyword.get(opts, :path_prefix, "/jobs")

    quote do
      post unquote(prefix) do
        case var!(conn).body_params do
          %{"payload" => payload} when is_map(payload) ->
            opts = []

            opts =
              if var!(conn).body_params["max_attempts"],
                do: Keyword.put(opts, :max_attempts, var!(conn).body_params["max_attempts"]),
                else: opts

            {:ok, id} = Core.Workers.JobQueue.submit(unquote(queue), payload, opts)

            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(202, Jason.encode!(%{message: "Job accepted", job_id: id}))

          %{"payload" => _} ->
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "'payload' must be a JSON object"}))

          _ ->
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "Missing 'payload' field"}))
        end
      end

      post "#{unquote(prefix)}/schedule" do
        payload = var!(conn).body_params["payload"]
        run_at_str = var!(conn).body_params["run_at"]

        if is_map(payload) and is_binary(run_at_str) do
          case DateTime.from_iso8601(run_at_str) do
            {:ok, run_at, _} ->
              {:ok, id} = Core.Workers.JobQueue.submit_at(unquote(queue), payload, run_at)

              var!(conn)
              |> put_resp_content_type("application/json")
              |> send_resp(
                202,
                Jason.encode!(%{message: "Job scheduled", job_id: id, run_at: run_at_str})
              )

            _ ->
              var!(conn)
              |> put_resp_content_type("application/json")
              |> send_resp(
                400,
                Jason.encode!(%{error: "Required: payload (object), run_at (ISO8601 string)"})
              )
          end
        else
          var!(conn)
          |> put_resp_content_type("application/json")
          |> send_resp(
            400,
            Jason.encode!(%{error: "Required: payload (object), run_at (ISO8601 string)"})
          )
        end
      end

      get unquote(prefix) do
        try do
          params = var!(conn).query_params

          opts =
            []
            |> then(fn o ->
              case params["status"] do
                nil -> o
                s -> Keyword.put(o, :status, String.to_existing_atom(s))
              end
            end)
            |> then(fn o ->
              case params["page"] do
                nil -> o
                p -> Keyword.put(o, :page, String.to_integer(p))
              end
            end)
            |> then(fn o ->
              case params["per_page"] do
                nil -> o
                pp -> Keyword.put(o, :per_page, String.to_integer(pp))
              end
            end)

          jobs = Core.Workers.JobQueue.all(unquote(queue), opts)

          var!(conn)
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(jobs))
        rescue
          ArgumentError ->
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(
              400,
              Jason.encode!(%{error: "Invalid status. Valid: queued, running, done, failed"})
            )
        end
      end

      get "#{unquote(prefix)}/:id" do
        case Integer.parse(var!(id)) do
          {int_id, ""} ->
            case Core.Workers.JobQueue.get(unquote(queue), int_id) do
              {:ok, job} ->
                var!(conn)
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(job))

              {:error, :not_found} ->
                var!(conn)
                |> put_resp_content_type("application/json")
                |> send_resp(404, Jason.encode!(%{error: "Job not found"}))
            end

          _ ->
            var!(conn)
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "Job ID must be an integer"}))
        end
      end
    end
  end
end
