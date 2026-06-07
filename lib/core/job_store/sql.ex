defmodule Core.JobStore.SQL do
  @moduledoc """
  Pure helper functions for building standard job-store SQL.

  Use this module when writing a custom `Core.JobStore` adapter for any
  SQL database (PostgreSQL, MySQL, SQLite, etc.).  It handles schema DDL,
  param encoding, and row deserialization so the adapter only needs to
  manage the connection.

  ## Example PostgreSQL adapter skeleton

      defmodule MyApp.JobStore.Postgres do
        @behaviour Core.JobStore
        alias Core.JobStore.SQL

        def init(_opts) do
          {table, index} = SQL.schema()
          Postgrex.query!(conn(), table, [])
          Postgrex.query!(conn(), index, [])
          {:ok, conn()}
        end

        def insert_job(conn, job) do
          {sql, params} = SQL.insert_params(job)
          %{rows: [[id]]} = Postgrex.query!(conn, sql <> " RETURNING id", params)
          {:ok, %Core.Workers.Job{job | id: id}}
        end

        def update_job(conn, id, changes) do
          {sql, params} = SQL.update_params(id, changes)
          Postgrex.query!(conn, sql, params)
          :ok
        end

        def get_job(conn, id) do
          %{rows: rows} = Postgrex.query!(conn, SQL.select_by_id(), [id])
          case rows do
            [row | _] -> {:ok, SQL.from_row(row)}
            []        -> {:error, :not_found}
          end
        end

        def list_jobs(conn, opts) do
          {sql, params} =
            if status = Keyword.get(opts, :status) do
              {SQL.select_by_status(), [Atom.to_string(status)]}
            else
              {SQL.select_all(), []}
            end

          %{rows: rows} = Postgrex.query!(conn, sql, params)
          Enum.map(rows, &SQL.from_row/1)
        end

        def cleanup(conn, opts) do
          {sql, params} = SQL.cleanup_params(Keyword.get(opts, :max_age_days, 7))
          Postgrex.query!(conn, sql, params)
          :ok
        end

        defp conn, do: MyApp.Repo
      end
  """

  alias Core.Workers.Job

  # ------------------------------------------------------------------
  # Schema
  # ------------------------------------------------------------------

  @create_table """
  CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL,
    status TEXT NOT NULL,
    attempt INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    result TEXT,
    retry_at TEXT,
    run_at TEXT,
    inserted_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT
  )
  """

  @create_index "CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status)"

  @doc "Returns the `{create_table, create_index}` DDL strings."
  def schema, do: {@create_table, @create_index}

  # ------------------------------------------------------------------
  # Queries
  # ------------------------------------------------------------------

  @doc "INSERT statement and params for a `%Job{}`."
  def insert_params(%Job{} = job) do
    sql = """
    INSERT INTO jobs
      (payload, status, attempt, max_attempts, result, retry_at, run_at, inserted_at, started_at, finished_at)
    VALUES
      (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    """

    params = [
      encode_json(job.payload),
      Atom.to_string(job.status),
      job.attempt,
      job.max_attempts,
      encode_json(job.result),
      iso8601(job.retry_at),
      iso8601(job.run_at),
      iso8601(job.inserted_at),
      iso8601(job.started_at),
      iso8601(job.finished_at)
    ]

    {sql, params}
  end

  @doc "UPDATE statement and params. `changes` is a keyword list of fields."
  def update_params(id, changes) do
    {fields, values} = build_set(changes)
    {"UPDATE jobs SET #{Enum.join(fields, ", ")} WHERE id = ?", values ++ [id]}
  end

  @doc "SELECT * with WHERE id = ?"
  def select_by_id, do: "SELECT * FROM jobs WHERE id = ?"

  @doc "SELECT * ordered by insertion time."
  def select_all, do: "SELECT * FROM jobs ORDER BY inserted_at ASC"

  @doc "SELECT * filtered by status."
  def select_by_status, do: "SELECT * FROM jobs WHERE status = ? ORDER BY inserted_at ASC"

  @doc "DELETE statement and cutoff param for old completed / failed jobs."
  def cleanup_params(max_age_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days, :day)
    {"DELETE FROM jobs WHERE status IN ('done', 'failed') AND finished_at < ?", [iso8601(cutoff)]}
  end

  # ------------------------------------------------------------------
  # Deserialization
  # ------------------------------------------------------------------

  @doc "Convert a raw row (list of columns in SELECT * order) into a `%Job{}`."
  def from_row([
        id,
        payload,
        status,
        attempt,
        max_attempts,
        result,
        retry_at,
        run_at,
        inserted_at,
        started_at,
        finished_at
      ]) do
    Job.from_map(%{
      id: id,
      payload: payload,
      status: status,
      attempt: attempt,
      max_attempts: max_attempts,
      result: result,
      retry_at: retry_at,
      run_at: run_at,
      inserted_at: inserted_at,
      started_at: started_at,
      finished_at: finished_at
    })
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp encode_json(nil), do: nil
  defp encode_json(val), do: Jason.encode!(val)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp build_set(changes) do
    Enum.reduce(changes, {[], []}, fn
      {:status, v}, {fs, vs} ->
        {["status = ?" | fs], [Atom.to_string(v) | vs]}

      {:attempt, v}, {fs, vs} ->
        {["attempt = ?" | fs], [v | vs]}

      {:result, v}, {fs, vs} ->
        {["result = ?" | fs], [encode_json(v) | vs]}

      {:retry_at, v}, {fs, vs} ->
        {["retry_at = ?" | fs], [iso8601(v) | vs]}

      {:run_at, v}, {fs, vs} ->
        {["run_at = ?" | fs], [iso8601(v) | vs]}

      {:started_at, v}, {fs, vs} ->
        {["started_at = ?" | fs], [iso8601(v) | vs]}

      {:finished_at, v}, {fs, vs} ->
        {["finished_at = ?" | fs], [iso8601(v) | vs]}

      _, acc ->
        acc
    end)
    |> then(fn {fs, vs} -> {Enum.reverse(fs), Enum.reverse(vs)} end)
  end
end
