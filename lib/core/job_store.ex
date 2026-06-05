defmodule Core.JobStore do
  @moduledoc """
  Behaviour for persisting job state across VM restarts.

  Forks can implement this behaviour to swap the storage backend
  (e.g. PostgreSQL, Redis, S3, etc.). The default `Core.JobStore.Memory`
  provides zero-durability in-memory IDs for prototyping.

  ## Configuration

      config :my_app, :job_store, Core.JobStore.SQLite
      config :my_app, :job_store_opts, database: "priv/jobs.db"

  All callbacks are invoked synchronously by `Core.Workers.JobQueue`.
  """

  alias Core.Workers.Job

  @type opts :: Keyword.t()

  @doc "Initialise the store (create tables, indexes, etc.)."
  @callback init(opts) :: :ok | {:error, term()}

  @doc "Persist a new job. Must return the job with an assigned `:id`."
  @callback insert_job(Job.t()) :: {:ok, Job.t()} | {:error, term()}

  @doc "Partially update a job by id. `changes` is a keyword list of fields."
  @callback update_job(pos_integer(), changes :: Keyword.t()) :: :ok | {:error, term()}

  @doc "Fetch a single job by id."
  @callback get_job(pos_integer()) :: {:ok, Job.t()} | {:error, :not_found}

  @doc "List jobs, optionally filtered by status."
  @callback list_jobs(Keyword.t()) :: [Job.t()]

  @doc "Remove old completed / failed jobs. `opts` contains `:max_age_days`."
  @callback cleanup(Keyword.t()) :: :ok
end
