# lib/core/workers/job_queue.ex
defmodule Core.Workers.JobQueue do
  @moduledoc """
  FIFO job queue backed by a pluggable `Core.JobStore`.

  Each `JobQueue` is a GenServer that maintains an in-memory queue of job IDs
  and a map of job structs. Jobs are persisted via the store so they survive
  VM restarts (when using a durable backend such as `Core.JobStore.SQLite`).

  ## Named queues

  You can start multiple isolated queues by giving each a unique `:name`:

      {Core.Workers.JobQueue, name: MyApp.EmailQueue, pool: MyApp.EmailPool}
      {Core.Workers.JobQueue, name: MyApp.MediaQueue, pool: MyApp.MediaPool}

  All public functions accept a server reference (atom or pid) as the first
  argument. The zero-arity versions operate on the default queue
  `Core.Workers.JobQueue`.

  ## Options

    * `:name` – registered name for this queue (default: `Core.Workers.JobQueue`)
    * `:pool` – the `WorkerPool` name to notify when new jobs arrive
    * `:store` – `Core.JobStore` module (default: `Core.JobStore.Memory`)
    * `:store_opts` – options passed to the store's `init/1`
    * `:cleanup_interval_ms` – how often to purge old jobs (default: 1 hour)
    * `:max_age_days` – retention for completed / failed jobs (default: 7)

  ## Worker notification

  When a job is submitted (or a retry is scheduled), `JobQueue` calls
  `notify_workers/1` which sends `:work_available` to every worker process
  under the configured `WorkerPool`. Workers use this as an immediate
  wake-up signal in addition to their fallback polling timer.
  """
  use GenServer
  require Logger
  alias Core.Workers.Job

  @default_cleanup_interval_ms :timer.hours(1)
  @default_max_age_days 7
  @max_dequeue_scan 1000

  ## ============================================================
  ## Client API
  ## ============================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a new job to the queue.
  Returns synchronously with the assigned job id.
  """
  def submit(payload) do
    submit(__MODULE__, payload, [])
  end

  def submit(payload, opts) do
    submit(__MODULE__, payload, opts)
  end

  def submit(server, payload, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    job = %Job{
      payload: payload,
      inserted_at: DateTime.utc_now(),
      status: :queued,
      max_attempts: max_attempts
    }

    GenServer.call(server, {:submit, job})
  end

  @doc """
  Submit a job to run at a specific future time.
  The job is persisted immediately but enters the in-memory queue only at `run_at`.
  """
  def submit_at(payload, %DateTime{} = run_at) do
    submit_at(__MODULE__, payload, run_at, [])
  end

  def submit_at(payload, %DateTime{} = run_at, opts) do
    submit_at(__MODULE__, payload, run_at, opts)
  end

  def submit_at(server, payload, %DateTime{} = run_at) do
    submit_at(server, payload, run_at, [])
  end

  def submit_at(server, payload, %DateTime{} = run_at, opts) do
    delay_ms = max(DateTime.diff(run_at, DateTime.utc_now(), :millisecond), 0)
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    job = %Job{
      payload: payload,
      inserted_at: DateTime.utc_now(),
      status: :queued,
      max_attempts: max_attempts,
      run_at: run_at
    }

    GenServer.call(server, {:submit_scheduled, job, delay_ms})
  end

  @doc """
  Claim the next available job for processing.
  Marks it as :running and returns it to the worker.
  """
  def claim_next do
    claim_next(__MODULE__)
  end

  def claim_next(server) do
    GenServer.call(server, :claim_next)
  end

  @doc """
  Mark a job as completed with a result
  """
  def mark_done(id, result) do
    mark_done(__MODULE__, id, result)
  end

  def mark_done(server, id, result) do
    GenServer.call(server, {:finish_job, id, :done, result})
  end

  @doc """
  Mark a job as failed with an error reason
  """
  def mark_failed(id, reason) do
    mark_failed(__MODULE__, id, reason)
  end

  def mark_failed(server, id, reason) do
    GenServer.call(server, {:fail_job, id, reason})
  end

  @doc """
  Get all jobs in the queue
  """
  def all do
    all(__MODULE__, [])
  end

  def all(opts) do
    all(__MODULE__, opts)
  end

  def all(server, opts) do
    GenServer.call(server, {:all, opts})
  end

  @doc """
  Get a specific job by ID
  """
  def get(id) do
    get(__MODULE__, id)
  end

  def get(server, id) do
    GenServer.call(server, {:get, id})
  end

  def stats do
    stats(__MODULE__)
  end

  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Reset the queue — clears all in-memory state. Intended for test use only.
  """
  def reset do
    reset(__MODULE__)
  end

  def reset(server) do
    GenServer.call(server, :reset)
  end

  ## ============================================================
  ## GenServer Callbacks
  ## ============================================================

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, Core.JobStore.Memory)
    store_opts = Keyword.get(opts, :store_opts, [])
    cleanup_interval = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)
    max_age_days = Keyword.get(opts, :max_age_days, @default_max_age_days)
    pool_name = Keyword.get(opts, :pool, Core.Workers.WorkerPool)

    case store.init(store_opts) do
      {:ok, store_state} ->
        now = DateTime.utc_now()

        # Load queued jobs. Split into "ready now" vs "scheduled for future".
        all_queued = store.list_jobs(store_state, status: :queued)

        {ready_jobs, future_jobs} =
          Enum.split_with(all_queued, fn job ->
            is_nil(job.run_at) or DateTime.compare(job.run_at, now) != :gt
          end)

        # Recover running jobs as queued (they never finished)
        running_jobs = store.list_jobs(store_state, status: :running)

        recovered_jobs =
          Enum.map(running_jobs, fn %Job{} = job ->
            recovered = %Job{job | status: :queued, attempt: job.attempt + 1}

            :ok =
              store.update_job(store_state, job.id, status: :queued, attempt: recovered.attempt)

            recovered
          end)

        all_ready = ready_jobs ++ recovered_jobs

        jobs_map =
          all_ready
          |> Enum.map(fn job -> {job.id, job} end)
          |> Map.new()

        queue =
          all_ready
          |> Enum.sort_by(& &1.inserted_at)
          |> Enum.reduce(:queue.new(), fn job, q -> :queue.in(job.id, q) end)

        # Re-schedule future jobs
        Enum.each(future_jobs, fn job ->
          delay_ms = max(DateTime.diff(job.run_at, now, :millisecond), 0)
          Process.send_after(self(), {:enqueue_delayed, job.id}, delay_ms)
        end)

        # Schedule periodic cleanup
        schedule_cleanup(cleanup_interval)

        {:ok,
         %{
           queue: queue,
           jobs: jobs_map,
           store: store,
           store_state: store_state,
           store_opts: store_opts,
           cleanup_interval_ms: cleanup_interval,
           max_age_days: max_age_days,
           pool_name: pool_name
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:submit, job},
        _from,
        %{queue: queue, jobs: jobs, store: store, store_state: store_state, pool_name: pool_name} =
          state
      ) do
    {:ok, job} = store.insert_job(store_state, job)

    updated_queue = :queue.in(job.id, queue)
    updated_jobs = Map.put(jobs, job.id, job)

    # Wake all idle workers immediately
    notify_workers(pool_name)

    {:reply, {:ok, job.id}, %{state | queue: updated_queue, jobs: updated_jobs}}
  end

  @impl true
  def handle_call(
        {:submit_scheduled, job, delay_ms},
        _from,
        %{jobs: jobs, store: store, store_state: store_state} = state
      ) do
    {:ok, job} = store.insert_job(store_state, job)

    # Persisted but not yet in the in-memory queue
    updated_jobs = Map.put(jobs, job.id, job)
    Process.send_after(self(), {:enqueue_delayed, job.id}, delay_ms)

    {:reply, {:ok, job.id}, %{state | jobs: updated_jobs}}
  end

  @impl true
  def handle_call(
        :claim_next,
        _from,
        %{queue: queue, jobs: jobs, store: store, store_state: store_state} = state
      ) do
    case dequeue_next_queued(queue, jobs) do
      {:ok, job_id, remaining_queue} ->
        %Job{} = job = Map.fetch!(jobs, job_id)

        updated_job = %Job{
          job
          | status: :running,
            started_at: DateTime.utc_now(),
            attempt: job.attempt + 1
        }

        updated_jobs = Map.put(jobs, job_id, updated_job)

        :ok =
          store.update_job(store_state, job_id,
            status: :running,
            started_at: updated_job.started_at,
            attempt: updated_job.attempt
          )

        new_state = %{state | queue: remaining_queue, jobs: updated_jobs}
        {:reply, {:ok, updated_job}, new_state}

      :empty ->
        {:reply, :empty, state}
    end
  end

  @impl true
  def handle_call(
        {:finish_job, id, status, result},
        _from,
        %{jobs: jobs, store: store, store_state: store_state} = state
      ) do
    case Map.get(jobs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Job{} = job ->
        updated_job = %Job{job | status: status, result: result, finished_at: DateTime.utc_now()}
        updated_jobs = Map.put(jobs, id, updated_job)

        :ok =
          store.update_job(store_state, id,
            status: status,
            result: result,
            finished_at: updated_job.finished_at
          )

        {:reply, :ok, %{state | jobs: updated_jobs}}
    end
  end

  @impl true
  def handle_call(
        {:fail_job, id, reason},
        _from,
        %{jobs: jobs, store: store, store_state: store_state} = state
      ) do
    case Map.get(jobs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Job{} = job ->
        if Job.retries_exhausted?(job) do
          # Permanently failed
          updated_job = %Job{
            job
            | status: :failed,
              result: reason,
              finished_at: DateTime.utc_now()
          }

          updated_jobs = Map.put(jobs, id, updated_job)

          :ok =
            store.update_job(store_state, id,
              status: :failed,
              result: reason,
              finished_at: updated_job.finished_at
            )

          {:reply, :ok, %{state | jobs: updated_jobs}}
        else
          # Schedule retry
          backoff = Job.backoff_ms(job)
          retry_at = DateTime.add(DateTime.utc_now(), backoff, :millisecond)

          updated_job = %Job{job | status: :queued, result: reason, retry_at: retry_at}

          updated_jobs = Map.put(jobs, id, updated_job)

          # Re-enqueue after backoff
          Process.send_after(self(), {:re_enqueue, id}, backoff)

          :ok =
            store.update_job(store_state, id,
              status: :queued,
              result: reason,
              retry_at: retry_at
            )

          Logger.warning(
            "Job #{id} failed (attempt #{job.attempt}/#{job.max_attempts}), retrying in #{backoff}ms"
          )

          {:reply, :ok, %{state | jobs: updated_jobs}}
        end
    end
  end

  @impl true
  def handle_call({:all, opts}, _from, %{jobs: jobs} = state) do
    status_filter = Keyword.get(opts, :status)
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = min(Keyword.get(opts, :per_page, 50), 200)

    result =
      jobs
      |> Map.values()
      |> then(fn list ->
        if status_filter, do: Enum.filter(list, &(&1.status == status_filter)), else: list
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get, id}, _from, %{jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil -> {:reply, {:error, :not_found}, state}
      job -> {:reply, {:ok, job}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, %{jobs: jobs} = state) do
    counts =
      jobs
      |> Map.values()
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {status, list} -> {status, length(list)} end)

    stats = %{
      queued: Map.get(counts, :queued, 0),
      running: Map.get(counts, :running, 0),
      done: Map.get(counts, :done, 0),
      failed: Map.get(counts, :failed, 0),
      total: map_size(jobs)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(
        :reset,
        _from,
        %{store: store, store_state: store_state, store_opts: store_opts} = state
      ) do
    store.cleanup(store_state, max_age_days: 0)

    case store.init(store_opts) do
      {:ok, new_store_state} ->
        {:reply, :ok, %{state | queue: :queue.new(), jobs: %{}, store_state: new_store_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:enqueue_delayed, id}, %{queue: queue} = state) do
    # Job already persisted; just add its id to the in-memory queue
    {:noreply, %{state | queue: :queue.in(id, queue)}}
  end

  @impl true
  def handle_info({:re_enqueue, id}, %{queue: queue, jobs: jobs, pool_name: pool_name} = state) do
    case Map.get(jobs, id) do
      %Job{status: :queued} = _job ->
        updated_queue = :queue.in(id, queue)
        # Wake workers so the retry is picked up immediately
        notify_workers(pool_name)
        {:noreply, %{state | queue: updated_queue}}

      _ ->
        # Job may have been cancelled or already processed
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        :cleanup,
        %{
          store: store,
          store_state: store_state,
          max_age_days: max_age_days,
          cleanup_interval_ms: interval
        } = state
      ) do
    :ok = store.cleanup(store_state, max_age_days: max_age_days)
    schedule_cleanup(interval)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{jobs: jobs, store: store, store_state: store_state}) do
    Logger.warning("JobQueue terminating (#{inspect(reason)}), marking running jobs as failed")

    Enum.each(jobs, fn
      {_id, %Job{status: :running} = job} ->
        Logger.error("Job #{job.id} was :running at shutdown — marking :failed")

        :ok =
          store.update_job(store_state, job.id,
            status: :failed,
            finished_at: DateTime.utc_now()
          )

      _ ->
        :ok
    end)

    :ok
  end

  ## ============================================================
  ## Private Helpers
  ## ============================================================

  # Pops from the front of the queue until a :queued job is found.
  # Bounded scan — discards at most @max_dequeue_scan stale entries.
  defp dequeue_next_queued(queue, jobs, scanned \\ 0)

  defp dequeue_next_queued(_queue, _jobs, scanned) when scanned >= @max_dequeue_scan do
    Logger.warning("JobQueue dequeue scan exceeded #{@max_dequeue_scan} stale entries")
    :empty
  end

  defp dequeue_next_queued(queue, jobs, scanned) do
    case :queue.out(queue) do
      {:empty, _} ->
        :empty

      {{:value, job_id}, remaining} ->
        case Map.get(jobs, job_id) do
          %Job{status: :queued} ->
            {:ok, job_id, remaining}

          _ ->
            dequeue_next_queued(remaining, jobs, scanned + 1)
        end
    end
  end

  defp notify_workers(pool_name) do
    # Notify all worker processes under the given WorkerPool supervisor
    if pid = Process.whereis(pool_name) do
      for {_, child_pid, :worker, _} <- Supervisor.which_children(pid), is_pid(child_pid) do
        send(child_pid, :work_available)
      end
    end
  rescue
    _ -> :ok
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
