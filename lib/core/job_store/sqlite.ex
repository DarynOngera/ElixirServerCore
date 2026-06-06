if Code.ensure_loaded?(Exqlite.Basic) do
  defmodule Core.JobStore.SQLite do
    @moduledoc """
    SQLite-backed job store with WAL mode enabled.

    Jobs are persisted synchronously. On VM restart, `:queued` and `:running`
    jobs are reloaded. `:running` jobs are reset to `:queued` so workers can
    reclaim them.

    ## Configuration

        config :my_app, :job_store, Core.JobStore.SQLite
        config :my_app, :job_store_opts, database: "priv/jobs.db"

    Requires `{:exqlite, "~> 0.29"}` in your `mix.exs` deps.

    ## Connection model

    Each operation opens and closes its own connection.  This is simple but
    limits throughput (roughly ~1,000 ops/sec on a typical SSD).  Because
    `Core.Workers.JobQueue` is a single GenServer, calls are serialized, so
    the risk of a `last_insert_rowid()` race between concurrent inserts is
    low.  For higher throughput implement a connection-pool adapter.
    """
    @behaviour Core.JobStore
    alias Exqlite.Basic
    alias Core.JobStore.SQL
    alias Core.Workers.Job

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    @impl true
    def init(opts) do
      db_path = Keyword.get(opts, :database, "jobs.db")
      db_path |> Path.dirname() |> File.mkdir_p!()

      conn = open!(db_path)
      {table, index} = SQL.schema()
      Basic.exec(conn, table)
      Basic.exec(conn, index)
      Basic.close(conn)
      :ok
    end

    @impl true
    def insert_job(%Job{} = job) do
      {sql, params} = SQL.insert_params(job)
      conn = open!()
      Basic.exec(conn, sql, params)
      {:ok, [[id]], _cols} = Basic.exec(conn, "SELECT last_insert_rowid()") |> Basic.rows()
      Basic.close(conn)

      {:ok, %Job{job | id: id}}
    end

    @impl true
    def update_job(id, changes) do
      {sql, params} = SQL.update_params(id, changes)
      conn = open!()
      Basic.exec(conn, sql, params)
      Basic.close(conn)
      :ok
    end

    @impl true
    def get_job(id) do
      conn = open!()
      {:ok, rows, _cols} = Basic.exec(conn, SQL.select_by_id(), [id]) |> Basic.rows()
      Basic.close(conn)

      case rows do
        [row | _] -> {:ok, SQL.from_row(row)}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def list_jobs(opts \\ []) do
      {sql, params} =
        if status = Keyword.get(opts, :status) do
          {SQL.select_by_status(), [Atom.to_string(status)]}
        else
          {SQL.select_all(), []}
        end

      conn = open!()
      {:ok, rows, _cols} = Basic.exec(conn, sql, params) |> Basic.rows()
      Basic.close(conn)

      Enum.map(rows, &SQL.from_row/1)
    end

    @impl true
    def cleanup(opts) do
      {sql, params} = SQL.cleanup_params(Keyword.get(opts, :max_age_days, 7))
      conn = open!()
      Basic.exec(conn, sql, params)
      Basic.close(conn)
      :ok
    end

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    defp open! do
      db_path = get_db_path()
      open!(db_path)
    end

    defp open!(path) do
      {:ok, conn} = Basic.open(path)
      {:ok, _query, _result, _conn} = Basic.exec(conn, "PRAGMA journal_mode = WAL")
      conn
    end

    defp get_db_path do
      Application.get_env(:servcore, :job_store_opts, [])
      |> Keyword.get(:database, "jobs.db")
    end
  end
end
