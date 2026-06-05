defmodule Core.JobStore.SQLTest do
  use ExUnit.Case, async: true
  alias Core.JobStore.SQL
  alias Core.Workers.Job

  describe "schema/0" do
    test "returns CREATE TABLE and CREATE INDEX strings" do
      {table, index} = SQL.schema()
      assert table =~ "CREATE TABLE IF NOT EXISTS jobs"
      assert table =~ "id INTEGER PRIMARY KEY AUTOINCREMENT"
      assert index =~ "CREATE INDEX IF NOT EXISTS idx_jobs_status"
    end
  end

  describe "insert_params/1" do
    test "returns INSERT SQL and correctly ordered params" do
      job = %Job{payload: %{"task" => "test"}, inserted_at: DateTime.utc_now()}
      {sql, params} = SQL.insert_params(job)

      assert sql =~ "INSERT INTO jobs"

      assert sql =~
               "(payload, status, attempt, max_attempts, result, retry_at, run_at, inserted_at, started_at, finished_at)"

      assert length(params) == 10
      assert hd(params) == ~s({"task":"test"})
    end

    test "encodes nil fields as nil" do
      job = %Job{payload: %{}, inserted_at: DateTime.utc_now()}
      {_sql, params} = SQL.insert_params(job)

      # result
      assert Enum.at(params, 4) == nil
      # retry_at
      assert Enum.at(params, 5) == nil
      # run_at
      assert Enum.at(params, 6) == nil
      # started_at
      assert Enum.at(params, 8) == nil
      # finished_at
      assert Enum.at(params, 9) == nil
    end
  end

  describe "from_row/1" do
    test "roundtrips with insert_params" do
      now = DateTime.utc_now()

      job = %Job{
        payload: %{"n" => 1},
        inserted_at: now,
        status: :queued,
        attempt: 2,
        max_attempts: 5,
        result: %{"ok" => true},
        retry_at: DateTime.add(now, 1000, :millisecond),
        run_at: DateTime.add(now, 2000, :millisecond),
        started_at: now,
        finished_at: now
      }

      {_sql, params} = SQL.insert_params(job)
      # prepend id
      row = [99 | params]
      recovered = SQL.from_row(row)

      assert recovered.id == 99
      assert recovered.payload == %{"n" => 1}
      assert recovered.status == :queued
      assert recovered.attempt == 2
      assert recovered.result == %{"ok" => true}
      assert recovered.max_attempts == 5
    end
  end

  describe "update_params/2" do
    test "builds dynamic SET clause" do
      {sql, params} = SQL.update_params(42, status: :done, result: %{"status" => "ok"})

      assert sql =~ "UPDATE jobs SET"
      assert sql =~ "status = ?"
      assert sql =~ "result = ?"
      assert sql =~ "WHERE id = ?"
      assert params == ["done", ~s({"status":"ok"}), 42]
    end

    test "ignores unknown change keys" do
      {sql, params} = SQL.update_params(1, unknown: "value", status: :running)

      assert sql =~ "status = ?"
      refute sql =~ "unknown"
      assert params == ["running", 1]
    end
  end

  describe "cleanup_params/1" do
    test "returns DELETE with ISO8601 cutoff" do
      {sql, [cutoff]} = SQL.cleanup_params(7)

      assert sql =~ "DELETE FROM jobs"
      assert sql =~ "status IN ('done', 'failed')"
      assert String.ends_with?(sql, "finished_at < ?")
      assert is_binary(cutoff)
    end
  end
end
