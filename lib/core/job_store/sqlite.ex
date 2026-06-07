if Code.ensure_loaded?(Exqlite.Basic) do
  defmodule Core.JobStore.SQLite do
    @moduledoc """
    SQLite-backed job store with WAL mode enabled.

    Jobs are persisted synchronously. On VM restart, `:queued` and `:running`
    jobs are reloaded. `:running` jobs are reset to `:queued` so workers can
    reclaim them.

    This is a **stateful** adapter: `init/1` returns the database path as
    opaque state, and every subsequent callback receives that state as its
    first argument. This allows multiple `JobQueue` processes to each use
    their own SQLite file without sharing global configuration.

    ## Configuration

        {Core.Workers.JobQueue,
          store: Core.JobStore.SQLite,
          store_opts: [database: "priv/jobs.db"]}

    Requires `{:exqlite, "~> 0.29"}` in your `mix.exs` deps.

    ## Options

    * `:database` – path to the SQLite file (default: `"jobs.db"`)

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
      {:ok, db_path}
    end

    @impl true
    def insert_job(db_path, %Job{} = job) do
      {sql, params} = SQL.insert_params(job)
      conn = open!(db_path)
      Basic.exec(conn, sql, params)
      {:ok, [[id]], _cols} = Basic.exec(conn, "SELECT last_insert_rowid()") |> Basic.rows()
      Basic.close(conn)

      {:ok, %Job{job | id: id}}
    end

    @impl true
    def update_job(db_path, id, changes) do
      {sql, params} = SQL.update_params(id, changes)
      conn = open!(db_path)
      Basic.exec(conn, sql, params)
      Basic.close(conn)
      :ok
    end

    @impl true
    def get_job(db_path, id) do
      conn = open!(db_path)
      {:ok, rows, _cols} = Basic.exec(conn, SQL.select_by_id(), [id]) |> Basic.rows()
      Basic.close(conn)

      case rows do
        [row | _] -> {:ok, SQL.from_row(row)}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def list_jobs(db_path, opts \\ []) do
      {sql, params} =
        if status = Keyword.get(opts, :status) do
          {SQL.select_by_status(), [Atom.to_string(status)]}
        else
          {SQL.select_all(), []}
        end

      conn = open!(db_path)
      {:ok, rows, _cols} = Basic.exec(conn, sql, params) |> Basic.rows()
      Basic.close(conn)

      Enum.map(rows, &SQL.from_row/1)
    end

    @impl true
    def cleanup(db_path, opts) do
      {sql, params} = SQL.cleanup_params(Keyword.get(opts, :max_age_days, 7))
      conn = open!(db_path)
      Basic.exec(conn, sql, params)
      Basic.close(conn)
      :ok
    end

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    defp open!(db_path) do
      {:ok, conn} = Basic.open(db_path)
      {:ok, _query, _result, _conn} = Basic.exec(conn, "PRAGMA journal_mode = WAL")
      conn
    end
  end
end
