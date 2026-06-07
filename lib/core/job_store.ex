defmodule Core.JobStore do
  @moduledoc """
  Behaviour for persisting job state across VM restarts.

  Forks can implement this behaviour to swap the storage backend
  (e.g. PostgreSQL, Redis, S3, etc.). The default `Core.JobStore.Memory`
  provides zero-durability in-memory IDs for prototyping.

  All callbacks are invoked synchronously by `Core.Workers.JobQueue`.
  Each callback receives the opaque `state` returned by `init/1` as its
  first argument, allowing multiple queues to use independent storage
  backends (e.g. separate SQLite files).
  """

  alias Core.Workers.Job

  @type opts :: Keyword.t()
  @type state :: term()

  @doc "Initialise the store (create tables, indexes, etc.). Returns opaque state."
  @callback init(opts) :: {:ok, state} | {:error, term()}

  @doc "Persist a new job. Must return the job with an assigned `:id`."
  @callback insert_job(state, Job.t()) :: {:ok, Job.t()} | {:error, term()}

  @doc "Partially update a job by id. `changes` is a keyword list of fields."
  @callback update_job(state, pos_integer(), changes :: Keyword.t()) :: :ok | {:error, term()}

  @doc "Fetch a single job by id."
  @callback get_job(state, pos_integer()) :: {:ok, Job.t()} | {:error, :not_found}

  @doc "List jobs, optionally filtered by status."
  @callback list_jobs(state, Keyword.t()) :: [Job.t()]

  @doc "Remove old completed / failed jobs. `opts` contains `:max_age_days`."
  @callback cleanup(state, Keyword.t()) :: :ok
end
