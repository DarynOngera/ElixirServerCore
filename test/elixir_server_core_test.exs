defmodule ElixirServerCoreTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Core.Workers.JobQueue

  @router Core.HTTP.Router

  setup do
    # Ensure JobQueue is running for each test
    case Process.whereis(JobQueue) do
      nil -> start_supervised!(JobQueue)
      _pid -> :ok
    end

    # Clean up job queue state between tests
    on_exit(fn ->
      if Process.whereis(JobQueue) != nil do
        :sys.replace_state(JobQueue, fn state ->
          %{state | queue: :queue.new(), jobs: %{}}
        end)
      end
    end)

    :ok
  end

  describe "GET /" do
    test "returns server status" do
      conn = conn(:get, "/")
      conn = @router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body == "Server is running"
    end
  end

  describe "GET /health" do
    test "returns OK when JobQueue is running" do
      conn = conn(:get, "/health")
      conn = @router.call(conn, [])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "OK"
    end

    test "returns DEGRADED when JobQueue is not running" do
      pid = Process.whereis(JobQueue)
      # Unregister name so router sees it as unavailable
      Process.unregister(JobQueue)

      try do
        conn = conn(:get, "/health")
        conn = @router.call(conn, [])

        assert conn.status == 503
        assert Jason.decode!(conn.resp_body)["status"] == "DEGRADED"
      after
        Process.register(pid, JobQueue)
      end
    end
  end

  describe "GET /stats" do
    test "returns job statistics" do
      conn = conn(:get, "/stats")
      conn = @router.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["queued"] == 0
      assert body["running"] == 0
      assert body["done"] == 0
      assert body["failed"] == 0
      assert body["total"] == 0
    end
  end

  describe "POST /jobs" do
    test "accepts a job with valid payload" do
      conn =
        conn(:post, "/jobs", Jason.encode!(%{"payload" => %{"task" => "test"}}))
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["message"] == "Job accepted"
      assert is_integer(body["job_id"])
    end

    test "accepts max_attempts option" do
      conn =
        conn(
          :post,
          "/jobs",
          Jason.encode!(%{
            "payload" => %{"task" => "test"},
            "max_attempts" => 5
          })
        )
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])
      assert conn.status == 202
    end

    test "returns 400 when payload is missing" do
      conn =
        conn(:post, "/jobs", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "Missing 'payload' field"
    end

    test "returns 400 when payload is not an object" do
      conn =
        conn(:post, "/jobs", Jason.encode!(%{"payload" => "not_a_map"}))
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "'payload' must be a JSON object"
    end
  end

  describe "POST /jobs/schedule" do
    test "schedules a job for future execution" do
      run_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      run_at_str = DateTime.to_iso8601(run_at)

      conn =
        conn(
          :post,
          "/jobs/schedule",
          Jason.encode!(%{
            "payload" => %{"task" => "future_task"},
            "run_at" => run_at_str
          })
        )
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["message"] == "Job scheduled"
      assert is_integer(body["job_id"])
      assert body["run_at"] == run_at_str
    end

    test "returns 400 for missing fields" do
      conn =
        conn(:post, "/jobs/schedule", Jason.encode!(%{"payload" => %{"task" => "test"}}))
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Required fields"
    end

    test "returns 400 for invalid ISO8601" do
      conn =
        conn(
          :post,
          "/jobs/schedule",
          Jason.encode!(%{
            "payload" => %{"task" => "test"},
            "run_at" => "not-a-date"
          })
        )
        |> put_req_header("content-type", "application/json")

      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Required fields"
    end
  end

  describe "GET /jobs" do
    test "returns empty list when no jobs exist" do
      conn = conn(:get, "/jobs")
      conn = @router.call(conn, [])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end

    test "returns list of jobs" do
      {:ok, id} = JobQueue.submit(%{"task" => "test_job"})

      conn = conn(:get, "/jobs")
      conn = @router.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body) == 1
      assert hd(body)["id"] == id
      assert hd(body)["status"] == "queued"
    end

    test "filters by status" do
      JobQueue.submit(%{"task" => "job1"})
      JobQueue.submit(%{"task" => "job2"})

      conn = conn(:get, "/jobs?status=queued")
      conn = @router.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body) == 2
      assert Enum.all?(body, &(&1["status"] == "queued"))
    end

    test "returns 400 for invalid status filter" do
      conn = conn(:get, "/jobs?status=invalid_status")
      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Invalid status filter"
    end

    test "supports pagination" do
      for i <- 1..5 do
        JobQueue.submit(%{"task" => "job#{i}"})
      end

      conn = conn(:get, "/jobs?page=1&per_page=2")
      conn = @router.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body) == 2
    end
  end

  describe "GET /jobs/:id" do
    test "returns a specific job" do
      {:ok, id} = JobQueue.submit(%{"task" => "specific_job"})

      conn = conn(:get, "/jobs/#{id}")
      conn = @router.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == id
      assert body["payload"]["task"] == "specific_job"
    end

    test "returns 404 for non-existent job" do
      conn = conn(:get, "/jobs/999999")
      conn = @router.call(conn, [])

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "Job not found"
    end

    test "returns 400 for invalid job id" do
      conn = conn(:get, "/jobs/not_an_integer")
      conn = @router.call(conn, [])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "Job ID must be an integer"
    end
  end

  describe "404 handling" do
    test "returns JSON error for unknown routes" do
      conn = conn(:get, "/unknown_route")
      conn = @router.call(conn, [])

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "Not found"
    end
  end
end
