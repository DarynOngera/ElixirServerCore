defmodule Core.JobStore.SQLiteTest do
  use ExUnit.Case, async: false
  alias Core.Workers.{Job, JobQueue}
  alias Core.JobStore.SQLite

  @db_path "/tmp/servcore_test_#{System.unique_integer([:positive])}.db"

  setup do
    # Clean up any stale file
    File.rm(@db_path)
    Application.put_env(:servcore, :job_store_opts, database: @db_path)
    :ok = SQLite.init(database: @db_path)

    on_exit(fn ->
      File.rm(@db_path)
      Application.delete_env(:servcore, :job_store_opts)
    end)

    :ok
  end

  describe "init/1" do
    test "creates the jobs table and index" do
      # init was called in setup; just verify we can insert
      job = %Job{payload: %{"task" => "init_test"}, inserted_at: DateTime.utc_now()}
      assert {:ok, %Job{id: id}} = SQLite.insert_job(job)
      assert is_integer(id) and id > 0
    end
  end

  describe "insert_job/1" do
    test "assigns an auto-increment id" do
      job1 = %Job{payload: %{"n" => 1}, inserted_at: DateTime.utc_now()}
      job2 = %Job{payload: %{"n" => 2}, inserted_at: DateTime.utc_now()}

      {:ok, job1} = SQLite.insert_job(job1)
      {:ok, job2} = SQLite.insert_job(job2)

      assert job2.id == job1.id + 1
    end

    test "persists all fields" do
      now = DateTime.utc_now()

      job = %Job{
        payload: %{"task" => "full"},
        inserted_at: now,
        status: :queued,
        attempt: 0,
        max_attempts: 5,
        run_at: DateTime.add(now, 60, :second)
      }

      {:ok, inserted} = SQLite.insert_job(job)
      {:ok, fetched} = SQLite.get_job(inserted.id)

      assert fetched.payload == %{"task" => "full"}
      assert fetched.status == :queued
      assert fetched.max_attempts == 5
      assert fetched.run_at != nil
    end
  end

  describe "get_job/1" do
    test "returns not_found for missing job" do
      assert SQLite.get_job(999_999) == {:error, :not_found}
    end
  end

  describe "update_job/2" do
    test "partially updates a job" do
      job = %Job{payload: %{"t" => 1}, inserted_at: DateTime.utc_now()}
      {:ok, job} = SQLite.insert_job(job)

      :ok = SQLite.update_job(job.id, status: :running, attempt: 1)
      {:ok, updated} = SQLite.get_job(job.id)

      assert updated.status == :running
      assert updated.attempt == 1
      assert updated.payload == %{"t" => 1}
    end

    test "stores result as json" do
      job = %Job{payload: %{"t" => 1}, inserted_at: DateTime.utc_now()}
      {:ok, job} = SQLite.insert_job(job)

      :ok = SQLite.update_job(job.id, result: %{"status" => "ok"})
      {:ok, updated} = SQLite.get_job(job.id)

      assert updated.result == %{"status" => "ok"}
    end
  end

  describe "list_jobs/1" do
    test "filters by status" do
      for i <- 1..3 do
        job = %Job{payload: %{"n" => i}, inserted_at: DateTime.utc_now(), status: :queued}
        {:ok, _} = SQLite.insert_job(job)
      end

      # Mark one as running
      [first | _] = SQLite.list_jobs(status: :queued)
      :ok = SQLite.update_job(first.id, status: :running)

      queued = SQLite.list_jobs(status: :queued)
      running = SQLite.list_jobs(status: :running)

      assert length(queued) == 2
      assert length(running) == 1
    end

    test "returns all jobs when no filter given" do
      job = %Job{payload: %{}, inserted_at: DateTime.utc_now()}
      {:ok, _} = SQLite.insert_job(job)

      assert length(SQLite.list_jobs([])) == 1
    end
  end

  describe "cleanup/1" do
    test "removes old done/failed jobs" do
      now = DateTime.utc_now()

      # Insert a done job from 10 days ago
      old_done = %Job{
        payload: %{},
        inserted_at: DateTime.add(now, -10, :day),
        status: :done,
        finished_at: DateTime.add(now, -10, :day)
      }

      {:ok, old_done} = SQLite.insert_job(old_done)
      :ok = SQLite.update_job(old_done.id, status: :done, finished_at: old_done.finished_at)

      # Insert a fresh done job
      fresh_done = %Job{
        payload: %{},
        inserted_at: now,
        status: :done,
        finished_at: now
      }

      {:ok, fresh_done} = SQLite.insert_job(fresh_done)
      :ok = SQLite.update_job(fresh_done.id, status: :done, finished_at: fresh_done.finished_at)

      SQLite.cleanup(max_age_days: 7)

      assert SQLite.get_job(old_done.id) == {:error, :not_found}
      assert {:ok, _} = SQLite.get_job(fresh_done.id)
    end
  end

  describe "JobQueue integration" do
    test "jobs survive a simulated VM restart" do
      db = "/tmp/servcore_restart_test_#{System.unique_integer([:positive])}.db"
      File.rm(db)
      on_exit(fn -> File.rm(db) end)

      # Use an unnamed JobQueue so we don't conflict with the global one
      Application.put_env(:servcore, :job_store_opts, database: db)
      {:ok, pid} = GenServer.start_link(JobQueue, store: SQLite, store_opts: [database: db])

      # Submit a job directly via GenServer.call
      job = %Job{payload: %{"task" => "survive"}, inserted_at: DateTime.utc_now()}
      {:ok, id} = GenServer.call(pid, {:submit, job})

      # Verify it's in memory
      assert {:ok, stored} = GenServer.call(pid, {:get, id})
      assert stored.payload == %{"task" => "survive"}

      # Simulate crash: stop without graceful shutdown
      Process.unlink(pid)
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Restart with same DB
      {:ok, pid2} = GenServer.start_link(JobQueue, store: SQLite, store_opts: [database: db])

      # Job should be recovered from SQLite
      assert {:ok, recovered} = GenServer.call(pid2, {:get, id})
      assert recovered.payload == %{"task" => "survive"}
      assert recovered.status == :queued

      Process.unlink(pid2)
      GenServer.stop(pid2)
    end
  end
end
