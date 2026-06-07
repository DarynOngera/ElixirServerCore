defmodule MultiQueueTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Core.Workers.{JobQueue, WorkerPool}

  defmodule CustomWorker do
    use GenServer
    require Logger
    alias Core.Workers.JobQueue

    @poll_interval 1_000

    def start_link(opts) do
      worker_id = Keyword.get(opts, :id, 1)
      pool_name = Keyword.get(opts, :pool, WorkerPool)
      name = :"#{pool_name}_Worker_#{worker_id}"
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      worker_id = Keyword.get(opts, :id, 1)
      queue = Keyword.get(opts, :queue, JobQueue)
      pool = Keyword.get(opts, :pool, WorkerPool)
      Logger.info("CustomWorker ##{worker_id} started")
      schedule_work()
      {:ok, %{id: worker_id, queue: queue, pool: pool}}
    end

    def handle_info(:work, state) do
      do_work(state)
      schedule_work()
      {:noreply, state}
    end

    def handle_info(:work_available, state) do
      do_work(state)
      schedule_work()
      {:noreply, state}
    end

    defp schedule_work do
      Process.send_after(self(), :work, @poll_interval)
    end

    defp do_work(%{queue: queue}) do
      case JobQueue.claim_next(queue) do
        {:ok, job} ->
          Process.sleep(10)
          JobQueue.mark_done(queue, job.id, %{status: "done", worker: :custom})

        :empty ->
          :noop
      end
    end
  end

  defmodule MultiQueueRouter do
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
    plug(:dispatch)

    import Core.HTTP.BaseRouter

    add_root_route()
    add_health_route([:queue_a, :queue_b])
    add_stats_route([:queue_a, :queue_b])
    add_job_routes(queue: :queue_a, path_prefix: "/jobs")
    add_job_routes(queue: :queue_b, path_prefix: "/media_jobs")

    match _ do
      send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
    end
  end

  defp wait_for_job_status(queue, id, expected_status, retries) do
    case JobQueue.get(queue, id) do
      {:ok, %{status: ^expected_status} = job} ->
        job

      _ when retries > 0 ->
        Process.sleep(50)
        wait_for_job_status(queue, id, expected_status, retries - 1)

      _ ->
        flunk("Job #{id} on #{inspect(queue)} did not reach status #{expected_status}")
    end
  end

  setup_all do
    # Ensure default queue is reset
    case Process.whereis(JobQueue) do
      nil -> :ok
      _pid -> JobQueue.reset()
    end

    {:ok, _} = JobQueue.start_link(name: :queue_a, pool: :pool_a, store: Core.JobStore.Memory, store_opts: [name: :queue_a_store])
    {:ok, _} = JobQueue.start_link(name: :queue_b, pool: :pool_b, store: Core.JobStore.Memory, store_opts: [name: :queue_b_store])

    on_exit(fn ->
      for name <- [:queue_a, :queue_b] do
        if pid = Process.whereis(name), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  setup do
    # Reset named queues between tests
    JobQueue.reset(:queue_a)
    JobQueue.reset(:queue_b)
    :ok
  end

  describe "named queue isolation" do
    test "jobs submitted to one queue are not visible in another" do
      {:ok, id} = JobQueue.submit(:queue_a, %{"task" => "a"}, [])

      assert {:ok, job} = JobQueue.get(:queue_a, id)
      assert job.payload == %{"task" => "a"}
      assert JobQueue.get(:queue_b, id) == {:error, :not_found}
    end

    test "claim_next is isolated per queue" do
      {:ok, _id} = JobQueue.submit(:queue_a, %{"task" => "a"}, [])

      assert {:ok, job} = JobQueue.claim_next(:queue_a)
      assert job.payload == %{"task" => "a"}
      assert JobQueue.claim_next(:queue_b) == :empty
    end

    test "stats are isolated per queue" do
      JobQueue.submit(:queue_a, %{"task" => "a"}, [])
      JobQueue.submit(:queue_b, %{"task" => "b"}, [])

      assert JobQueue.stats(:queue_a).queued == 1
      assert JobQueue.stats(:queue_b).queued == 1
      assert JobQueue.stats(:queue_a).total == 1
      assert JobQueue.stats(:queue_b).total == 1
    end
  end

  describe "named worker pool" do
    test "workers are started under unique names" do
      start_supervised!(
        %{
          id: :pool_a,
          start:
            {WorkerPool, :start_link,
             [[name: :pool_a, worker: CustomWorker, size: 2, queue: :queue_a]]},
          restart: :temporary
        },
        []
      )

      assert Process.whereis(:pool_a_Worker_1) != nil
      assert Process.whereis(:pool_a_Worker_2) != nil
    end

    test "workers only claim from their assigned queue" do
      start_supervised!(
        %{
          id: :pool_a,
          start:
            {WorkerPool, :start_link,
             [[name: :pool_a, worker: CustomWorker, size: 1, queue: :queue_a]]},
          restart: :temporary
        },
        []
      )

      start_supervised!(
        %{
          id: :pool_b,
          start:
            {WorkerPool, :start_link,
             [[name: :pool_b, worker: CustomWorker, size: 1, queue: :queue_b]]},
          restart: :temporary
        },
        []
      )

      {:ok, id_a} = JobQueue.submit(:queue_a, %{"task" => "a"}, [])
      {:ok, id_b} = JobQueue.submit(:queue_b, %{"task" => "b"}, [])

      # Poll until workers process the jobs
      job_a = wait_for_job_status(:queue_a, id_a, :done, 20)
      job_b = wait_for_job_status(:queue_b, id_b, :done, 20)

      assert job_a.result.worker == :custom
      assert job_b.result.worker == :custom
    end
  end

  describe "multi-queue router" do
    test "POST /jobs submits to queue_a" do
      conn =
        conn(:post, "/jobs", Jason.encode!(%{"payload" => %{"task" => "via_default"}}))
        |> put_req_header("content-type", "application/json")

      conn = MultiQueueRouter.call(conn, [])
      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      id = body["job_id"]

      assert {:ok, job} = JobQueue.get(:queue_a, id)
      assert job.payload == %{"task" => "via_default"}
      assert JobQueue.get(:queue_b, id) == {:error, :not_found}
    end

    test "POST /media_jobs submits to queue_b" do
      conn =
        conn(:post, "/media_jobs", Jason.encode!(%{"payload" => %{"task" => "via_media"}}))
        |> put_req_header("content-type", "application/json")

      conn = MultiQueueRouter.call(conn, [])
      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      id = body["job_id"]

      assert {:ok, job} = JobQueue.get(:queue_b, id)
      assert job.payload == %{"task" => "via_media"}
      assert JobQueue.get(:queue_a, id) == {:error, :not_found}
    end

    test "GET /health returns per-queue status" do
      conn = conn(:get, "/health")
      conn = MultiQueueRouter.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "OK"
      assert body["queues"][":queue_a"] == true
      assert body["queues"][":queue_b"] == true
    end

    test "GET /stats aggregates across queues" do
      JobQueue.submit(:queue_a, %{"task" => "a"}, [])
      JobQueue.submit(:queue_b, %{"task" => "b"}, [])

      conn = conn(:get, "/stats")
      conn = MultiQueueRouter.call(conn, [])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["queued"] == 2
      assert body["total"] == 2
    end
  end
end
