defmodule ElixirServerCoreTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Core.Workers.JobQueue

  @router Core.HTTP.Router

  setup do
    # Ensure JobQueue is running for each test with explicit Memory store
    case Process.whereis(JobQueue) do
      nil ->
        start_supervised!({JobQueue, store: Core.JobStore.Memory, store_opts: []})

      _pid ->
        :ok = JobQueue.reset()
    end

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
      assert Jason.decode!(conn.resp_body)["error"] =~ "Required"
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
      assert Jason.decode!(conn.resp_body)["error"] =~ "Required"
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
      assert Jason.decode!(conn.resp_body)["error"] =~ "Invalid status"
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

  describe "retry/backoff path" do
    test "mark_failed re-queues job when retries remain" do
      {:ok, id} = JobQueue.submit(%{"task" => "retry_test"}, max_attempts: 3)

      # Claim the job (increments attempt to 1)
      {:ok, job} = JobQueue.claim_next()
      assert job.id == id
      assert job.attempt == 1

      # Mark as failed — should re-queue since 1 < 3
      :ok = JobQueue.mark_failed(id, %{error: "transient failure"})

      # Job should be back in :queued with retry_at set
      {:ok, job} = JobQueue.get(id)
      assert job.status == :queued
      assert not is_nil(job.retry_at)
      assert job.attempt == 1

      # After backoff timer fires, it should be claimable again
      # Simulate the timer firing
      send(Process.whereis(JobQueue), {:re_enqueue, id})
      # Give it a moment to process
      Process.sleep(50)

      {:ok, job2} = JobQueue.claim_next()
      assert job2.id == id
      assert job2.attempt == 2
    end

    test "mark_failed permanently fails job when retries exhausted" do
      {:ok, id} = JobQueue.submit(%{"task" => "fail_test"}, max_attempts: 2)

      # Claim (attempt -> 1)
      {:ok, _job} = JobQueue.claim_next()

      # Fail (attempt 1 < 2, so re-queued)
      :ok = JobQueue.mark_failed(id, %{error: "first failure"})
      send(Process.whereis(JobQueue), {:re_enqueue, id})
      Process.sleep(50)

      # Re-claim (attempt -> 2)
      {:ok, _job} = JobQueue.claim_next()

      # Fail again (attempt 2 >= max_attempts 2, so permanently failed)
      :ok = JobQueue.mark_failed(id, %{error: "final failure"})

      {:ok, job} = JobQueue.get(id)
      assert job.status == :failed
      assert job.result == %{error: "final failure"}
    end

    test "backoff_ms increases exponentially" do
      now = DateTime.utc_now()
      job = %Core.Workers.Job{payload: %{}, inserted_at: now, attempt: 1}
      assert Core.Workers.Job.backoff_ms(job) == 2_000

      job = %Core.Workers.Job{payload: %{}, inserted_at: now, attempt: 2}
      assert Core.Workers.Job.backoff_ms(job) == 4_000

      job = %Core.Workers.Job{payload: %{}, inserted_at: now, attempt: 5}
      assert Core.Workers.Job.backoff_ms(job) == 30_000

      # Capped at 30s
      job = %Core.Workers.Job{payload: %{}, inserted_at: now, attempt: 10}
      assert Core.Workers.Job.backoff_ms(job) == 30_000
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
