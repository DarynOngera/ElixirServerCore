# Elixir Server Core

Build durable background-processing services in Elixir without the complexity of a full application framework.

Elixir Server Core is a lightweight toolkit for building standalone worker services. It combines HTTP endpoints, supervised job execution, pluggable persistence, retries, scheduling, and observability into a minimal foundation that you can use as a library or fork as a starting point.

Whether you're building a PDF conversion service, media-processing pipeline, webhook receiver, or automation backend, Elixir Server Core provides the essential infrastructure while staying close to OTP principles.

## Typical Use Cases

- **Media processing** — video transcoding, image resizing, thumbnail generation
- **Document workflows** — PDF optimization, OCR, format conversion
- **Webhook ingestion** — receive requests and process them asynchronously
- **Automation services** — scheduled jobs, background tasks, integrations
- **Single-node deployments** — SQLite-backed durability on a VPS, edge device, or homelab server
- **Learning OTP** — understand how job queues, workers, supervision trees, and retries are implemented

## Why Not Phoenix + Oban?

Phoenix and Oban are excellent tools and should be the default choice for many production systems.

Elixir Server Core targets a different use case: standalone worker services where you don't need a full web application, database layer, or distributed job-processing platform.

If your service only needs:

- HTTP endpoints
- A durable job queue
- Worker supervision
- Retries and scheduling
- Basic observability

Then a smaller toolkit can be easier to understand, customize, and deploy.

## The Problem

Many background-processing services start with a simple requirement:

> Accept work, queue it, process it, retry failures, and survive restarts.

Achieving that often means assembling multiple libraries or adopting a larger framework than the problem requires.

## The Solution

Elixir Server Core provides the building blocks for specialized worker services:

- **Bandit** for HTTP endpoints
- **OTP supervision trees** for fault tolerance
- **Background job queues** with worker pools
- **Exponential backoff retries**
- **Job scheduling**
- **Telemetry instrumentation**
- **Pluggable persistence**

Use in-memory storage for rapid prototyping, SQLite for lightweight durability, or implement the `Core.JobStore` behaviour to integrate with your preferred database.

The result is a small, understandable foundation that stays close to Elixir's strengths while remaining easy to extend, fork, and deploy.

---

## Features

* Forkable server framework for domain-specific services
* HTTP server using Bandit
* OTP supervision trees for fault tolerance
* Background job queue with automatic worker execution
* In-memory job tracking with full lifecycle management
* Worker pool for concurrent job processing
* Job scheduling (cron-like future execution)
* Exponential backoff retries with configurable max attempts
* Observability via Telemetry
* Optional Prometheus + Grafana integration (not implemented)
* RESTful API with JSON support
* Pagination and filtering for job listings
* Health check endpoint
* Modular and extensible architecture

---

## Quick Start

### As a Library (add to deps)

```elixir
# mix.exs
{:servcore, "~> 0.1"}

# config/config.exs
config :servcore,
  router: MyApp.Router,
  port: 4000,
  job_store: Core.JobStore.SQLite,
  job_store_opts: [database: "priv/jobs.db"]
```

The framework auto-starts `JobQueue`, `WorkerPool`, and `Bandit` with your router.

### Multiple Worker Pipelines

You can define independent job queues and worker pools for different job types:

```elixir
# config/config.exs
config :servcore,
  router: MyApp.Router,
  port: 4000,
  start_http: true,
  pipelines: [
    [
      queue_name: MyApp.EmailQueue,
      pool_name: MyApp.EmailPool,
      worker: MyApp.EmailWorker,
      pool_size: 4,
      job_store: Core.JobStore.SQLite,
      job_store_opts: [database: "priv/email.db"]
    ],
    [
      queue_name: MyApp.MediaQueue,
      pool_name: MyApp.MediaPool,
      worker: MyApp.MediaWorker,
      pool_size: 2,
      job_store: Core.JobStore.SQLite,
      job_store_opts: [database: "priv/media.db"]
    ]
  ]
```

Then mount their routes separately in your router:

```elixir
import Core.HTTP.BaseRouter

add_job_routes(queue: MyApp.EmailQueue, path_prefix: "/email_jobs")
add_job_routes(queue: MyApp.MediaQueue, path_prefix: "/media_jobs")
add_health_route([MyApp.EmailQueue, MyApp.MediaQueue])
add_stats_route([MyApp.EmailQueue, MyApp.MediaQueue])
```

### Manual Supervision (library, full control)

```elixir
# config/config.exs
config :servcore, start_http: false

# application.ex
children = [
  {Core.Workers.JobQueue, name: MyApp.Queue, store: Core.JobStore.SQLite, store_opts: [database: "jobs.db"]},
  {Core.Workers.WorkerPool, name: MyApp.Pool, worker: MyApp.Worker, size: 4, queue: MyApp.Queue},
  {Bandit, plug: MyApp.Router, scheme: :http, port: 4000, http_2_options: [enabled: true]}
]
```

### As a Fork (customize internals)

Clone, rename the app in `mix.exs`, edit `lib/core/` directly. See [FORKING.md](FORKING.md).

---

## High-Level Architecture

```
Client ──HTTP──▶ Router ──▶ OTP Supervision Tree
                                │
                                ├── JobQueue (GenServer)
                                │   ├── Queue: Job IDs
                                │   └── Jobs: Job Data Map
                                │
                                ├── WorkerPool (Supervisor)
                                │   └── Workers (GenServer) × N
                                │       └── Poll & Execute Jobs
                                │
                                └── Telemetry Events
                                    │
                                    ▼
                               /metrics (optional)
                               Prometheus → Grafana
```

---

## Job Lifecycle

Jobs progress through the following states:

1. **`:queued`** - Job submitted and waiting for a worker
2. **`:running`** - Job claimed by a worker and being processed
3. **`:done`** - Job completed successfully with a result
4. **`:failed`** - Job encountered an error during processing

Jobs can also transition back to `:queued` when a retry is scheduled after a failure. Each job has a configurable `max_attempts` (default: 3) and uses exponential backoff between retries.

Jobs remain in the queue throughout their lifecycle, allowing you to track their complete history and status via the API. The worker pool polls the queue, claims the next available job, executes it, and updates its status accordingly.

---

## How Job Execution Works

Understanding the exact path a job takes from submission to completion helps when writing custom workers or debugging processing issues.

### 1. Job Submission

A client submits a job via HTTP:

```bash
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "send_email", "to": "user@example.com"}}'
```

The router calls `JobQueue.submit/2`, which:
- Persists the job via the configured `Core.JobStore`
- Assigns a unique job ID
- Inserts the ID into the in-memory FIFO queue
- Sends `:work_available` messages to every worker in the associated `WorkerPool`

### 2. Worker Notification

Workers are notified of new work through two mechanisms:

**Immediate wake-up:**
When a job is submitted, `JobQueue` calls `notify_workers/1`, which iterates over all child processes under the configured `WorkerPool` supervisor and sends each one a `:work_available` message.

**Fallback polling:**
Each worker also schedules a recurring `:work` message every `@poll_interval` ms (default: 1,000 ms). This ensures jobs are eventually picked up even if the wake-up message is missed.

### 3. Job Claiming

Upon receiving `:work_available` or `:work`, the worker calls `JobQueue.claim_next/1`:

```elixir
case JobQueue.claim_next(MyApp.Queue) do
  {:ok, job} -> execute(job, state)
  :empty     -> :noop
end
```

`claim_next/1` is a synchronous `GenServer.call`, which serializes access to the queue. It atomically:
1. Pops the next `:queued` job ID from the FIFO
2. Updates the job's status to `:running`
3. Increments the `attempt` counter
4. Returns the full job struct to the worker

Because `JobQueue` is a single GenServer, there is no risk of two workers claiming the same job.

### 4. Performing the Work

The worker calls `perform_work/1`, passing the job struct. **This is the hook where your business logic runs.**

The default `Core.Workers.Worker` provides a placeholder:

```elixir
defp perform_work(job) do
  Process.sleep(100)
  %{status: "completed", job_id: job.id, processed_at: DateTime.utc_now()}
end
```

To process real work, create a custom worker module that overrides this function:

```elixir
defmodule MyApp.EmailWorker do
  # ... GenServer boilerplate (start_link, init, handle_info) ...

  defp perform_work(job) do
    case job.payload do
      %{"task" => "send_email", "to" => recipient} ->
        MyApp.Mailer.send(recipient)
        %{status: "sent", to: recipient}

      _ ->
        %{error: "Unknown task"}
    end
  end
end
```

### 5. Reporting the Result

After `perform_work/1` returns:

**On success:**
```elixir
JobQueue.mark_done(MyApp.Queue, job.id, result)
```
The job's status transitions to `:done`, and `result` is stored.

**On exception:**
```elixir
error_details = %{error: Exception.message(error), stacktrace: ...}
JobQueue.mark_failed(MyApp.Queue, job.id, error_details)
```
The job's status transitions to `:failed`. If retries remain, `JobQueue` schedules a retry with exponential backoff and re-inserts the job ID into the queue after the backoff period.

### Summary Flow

```
Client POST /jobs
    |
    v
Router --> JobQueue.submit(payload)
    |           |
    |           +---> Store.persist(job)
    |           +---> Queue.in(job.id)
    |           +---> notify_workers(pool)
    |                     |
    |                     v
    |               WorkerPool workers
    |                     |
    |                     +---> receive :work_available
    |                     +---> JobQueue.claim_next()
    |                     |         |
    |                     |         +---> status: :running
    |                     |         +---> attempt + 1
    |                     |         +---> return job
    |                     v
    |               perform_work(job)  <-- YOUR LOGIC HERE
    |                     |
    |           +---------+---------+
    |           |                   |
    |           v                   v
    |   mark_done()           mark_failed()
    |   status: :done          status: :failed
    |   result stored          or retry scheduled
    v
Client GET /jobs/:id
```

---

## Project Structure

```text
servcore/
├── lib/
│   ├── core/
│   │   ├── http/
│   │   │   ├── router.ex              # HTTP routing and endpoints
│   │   │   └── base_router.ex         # Base router for forking
│   │   ├── workers/
│   │   │   ├── job.ex                 # Job struct definition
│   │   │   ├── job_queue.ex           # Job queue GenServer
│   │   │   ├── worker.ex              # Background job worker
│   │   │   └── worker_pool.ex         # Worker pool supervisor
│   │   ├── telemetry/
│   │   │   ├── events.ex              # Telemetry event definitions
│   │   │   └── metrics.ex             # Telemetry metrics definitions
│   │   └── capability/                # Optional reusable capabilities
│   │       ├── http.ex                # Alternative HTTP capability
│   │       ├── work_queue.ex          # Work queue capability
│   │       ├── metrics.ex             # Capability metrics
│   │       └── server_template.ex     # Template for forked servers
│   └── elixir_server_core/
│       └── application.ex             # Main application supervisor
├── config/
│   └── config.exs
├── test/
│   ├── elixir_server_core_test.exs   # Integration tests
│   └── test_helper.exs
├── mix.exs                            # Project dependencies
├── mix.lock
└── README.md
```

---

## Getting Started

### Requirements

* Elixir 1.14 or newer
* Erlang/OTP 26 or newer

---

### Setup

```bash
# Clone the repository
git clone https://github.com/DarynOngera/ServCore.git
cd servcore

# Install dependencies
mix deps.get

# Compile the project
mix compile
```

---

### Running the Server

```bash
mix run --no-halt
```

Default address:
```
http://localhost:4000
```

You should see:
```
[info] Starting server on port 4000
[info] http://localhost:4000
[info] Worker started
```

---

## API Endpoints

### Overview

| Method | Endpoint         | Description                          |
|--------|-----------------|--------------------------------------|
| GET    | `/`             | Root endpoint - server status        |
| GET    | `/health`       | Health check                         |
| GET    | `/stats`        | Job statistics                       |
| POST   | `/jobs`         | Submit a new job                     |
| POST   | `/jobs/schedule`| Schedule a job for future execution  |
| GET    | `/jobs`         | List all jobs                        |
| GET    | `/jobs/:id`     | Get a specific job by ID             |

---

### Endpoint Details

#### `GET /` - Root Endpoint

Returns a simple status message.

**Request:**
```bash
curl http://localhost:4000/
```

**Response:**
```
Server is running
```

---

#### `GET /health` - Health Check

Returns the health status of the server.

**Request:**
```bash
curl http://localhost:4000/health
```

**Response:**
```json
{"status": "OK"}
```

If the JobQueue process is not running, returns:
```json
{"status": "DEGRADED"}
```

---

#### `GET /stats` - Job Statistics

Returns aggregate counts of jobs by status.

**Request:**
```bash
curl http://localhost:4000/stats
```

**Response:**
```json
{
  "queued": 2,
  "running": 1,
  "done": 5,
  "failed": 0,
  "total": 8
}
```

---

#### `POST /jobs` - Submit a New Job

Submits a new job to the queue for processing.

**Request:**
```bash
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "process_data", "value": 42}}'
```

**Response (202 Accepted):**
```json
{
  "message": "Job accepted",
  "job_id": 123
}
```

**Error Response (400 Bad Request):**
```json
{
  "error": "Missing 'payload' field"
}
```

**Optional Parameters:**

| Parameter      | Type    | Description                                    |
|---------------|---------|------------------------------------------------|
| `max_attempts`| integer | Maximum retry attempts (default: 3)            |

**Examples:**

```bash
# Simple task
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "send_email", "recipient": "user@example.com"}}'

# Complex payload
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "generate_report", "filters": {"date_range": "2024-01-01:2024-12-31", "type": "sales"}}}'

# Batch processing
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "process_batch", "items": [1, 2, 3, 4, 5]}}'

# With custom retry limit
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "critical_task"}, "max_attempts": 5}'
```

---

#### `POST /jobs/schedule` - Schedule a Job

Schedules a job to run at a specific future time.

**Request:**
```bash
curl -X POST http://localhost:4000/jobs/schedule \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {"task": "send_reminder"},
    "run_at": "2025-12-31T23:59:59Z"
  }'
```

**Response (202 Accepted):**
```json
{
  "message": "Job scheduled",
  "job_id": 456,
  "run_at": "2025-12-31T23:59:59Z"
}
```

**Error Response (400 Bad Request):**
```json
{
  "error": "Required fields: payload (object), run_at (ISO8601)"
}
```

---

#### `GET /jobs` - List All Jobs

Returns jobs in the queue with their current status. Supports filtering by status and pagination. Sorted by insertion time descending.

**Query Parameters:**

| Parameter  | Type    | Description                                  |
|-----------|---------|----------------------------------------------|
| `status`  | string  | Filter by status: `queued`, `running`, `done`, `failed` |
| `page`    | integer | Page number (default: 1)                     |
| `per_page`| integer | Items per page, max 200 (default: 50)      |

**Request:**
```bash
curl http://localhost:4000/jobs
```

**Response (200 OK):**
```json
[
  {
    "id": 123,
    "payload": {"task": "process_data", "value": 42},
    "status": "done",
    "inserted_at": "2025-12-28T17:24:48.957749Z",
    "started_at": "2025-12-28T17:24:49.566352Z",
    "finished_at": "2025-12-28T17:24:49.667314Z",
    "result": {
      "status": "completed",
      "job_id": 123,
      "processed_at": "2025-12-28T17:24:49.667198Z"
    }
  },
  {
    "id": 124,
    "payload": {"task": "send_email"},
    "status": "running",
    "inserted_at": "2025-12-28T17:25:01.123456Z",
    "started_at": "2025-12-28T17:25:02.234567Z",
    "finished_at": null,
    "result": null
  },
  {
    "id": 125,
    "payload": {"task": "generate_report"},
    "status": "queued",
    "inserted_at": "2025-12-28T17:25:05.345678Z",
    "started_at": null,
    "finished_at": null,
    "result": null
  }
]
```

**Pretty Print Response:**
```bash
curl http://localhost:4000/jobs | jq
```

**Filter by Status (API query parameter):**
```bash
# Show only completed jobs
curl "http://localhost:4000/jobs?status=done"

# Show only running jobs
curl "http://localhost:4000/jobs?status=running"
```

**Pagination:**
```bash
# Get page 2 with 10 items per page
curl "http://localhost:4000/jobs?page=2&per_page=10"
```

**Filter by Status (using jq):**
```bash
# Count jobs by status
curl -s http://localhost:4000/jobs | jq 'group_by(.status) | map({status: .[0].status, count: length})'
```

---

#### `GET /jobs/:id` - Get Specific Job

Returns detailed information about a specific job.

**Request:**
```bash
curl http://localhost:4000/jobs/123
```

**Response (200 OK):**
```json
{
  "id": 123,
  "payload": {"task": "process_data", "value": 42},
  "status": "done",
  "inserted_at": "2025-12-28T17:24:48.957749Z",
  "started_at": "2025-12-28T17:24:49.566352Z",
  "finished_at": "2025-12-28T17:24:49.667314Z",
  "result": {
    "status": "completed",
    "job_id": 123,
    "processed_at": "2025-12-28T17:24:49.667198Z"
  }
}
```

**Error Response (404 Not Found):**
```json
{
  "error": "Job not found"
}
```

**Examples:**

```bash
# Get job details
curl http://localhost:4000/jobs/123

# Pretty print with jq
curl http://localhost:4000/jobs/123 | jq

# Extract specific fields
curl -s http://localhost:4000/jobs/123 | jq '{id: .id, status: .status, result: .result}'

# Check if job is complete
curl -s http://localhost:4000/jobs/123 | jq '.status == "done"'
```

---

## Complete Workflow Example

### 1. Submit Multiple Jobs

```bash
# Submit job 1
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "backup_database"}}'

# Submit job 2
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "send_notifications"}}'

# Submit job 3 with custom retry limit
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "generate_reports"}, "max_attempts": 5}'

# Schedule a job for tomorrow
RUN_AT=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
curl -X POST http://localhost:4000/jobs/schedule \
  -H "Content-Type: application/json" \
  -d "{\"payload\": {\"task\": \"daily_cleanup\"}, \"run_at\": \"$RUN_AT\"}"
```

### 2. Monitor Job Progress

```bash
# List all jobs
curl http://localhost:4000/jobs | jq

# Quick stats overview
curl http://localhost:4000/stats | jq

# Watch jobs in real-time (refresh every 2 seconds)
watch -n 2 'curl -s http://localhost:4000/jobs | jq'
```

### 3. Check Specific Job Status

```bash
# Get job by ID (replace with actual job ID)
curl http://localhost:4000/jobs/1 | jq

# Poll until job is done
while true; do
  STATUS=$(curl -s http://localhost:4000/jobs/1 | jq -r '.status')
  echo "Job status: $STATUS"
  if [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; then
    break
  fi
  sleep 1
done
```

### 4. Analyze Results

```bash
# Get all completed jobs with their results
curl -s http://localhost:4000/jobs | jq '[.[] | select(.status == "done") | {id: .id, task: .payload.task, result: .result}]'

# Calculate average processing time
curl -s http://localhost:4000/jobs | jq '[.[] | select(.started_at != null and .finished_at != null)] | map((.finished_at | fromdateiso8601) - (.started_at | fromdateiso8601)) | add / length'
```

---

## Testing

### Run Tests

```bash
# Run all tests
mix test

# Run tests with coverage
mix test --cover

# Run specific test file
mix test test/elixir_server_core_test.exs

# Run tests in watch mode (requires mix_test_watch)
mix test.watch
```

### Manual Testing Script

Create a file `test_api.sh`:

```bash
#!/bin/bash

echo "=== Testing Elixir Server Core API ==="
echo

echo "1. Health Check"
curl -s http://localhost:4000/health | jq
echo

echo "2. Stats"
curl -s http://localhost:4000/stats | jq
echo

echo "3. Submit Job 1"
JOB1=$(curl -s -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "test_job_1"}}')
echo $JOB1 | jq
JOB1_ID=$(echo $JOB1 | jq -r '.job_id')
echo

echo "4. Submit Job 2"
JOB2=$(curl -s -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "test_job_2"}, "max_attempts": 5}')
echo $JOB2 | jq
JOB2_ID=$(echo $JOB2 | jq -r '.job_id')
echo

echo "5. Schedule Future Job"
RUN_AT=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
curl -s -X POST http://localhost:4000/jobs/schedule \
  -H "Content-Type: application/json" \
  -d "{\"payload\": {\"task\": \"future_job\"}, \"run_at\": \"$RUN_AT\"}" | jq
echo

echo "6. Wait for processing..."
sleep 2
echo

echo "7. Get All Jobs"
curl -s http://localhost:4000/jobs | jq
echo

echo "8. Get Job 1 Details"
curl -s http://localhost:4000/jobs/$JOB1_ID | jq
echo

echo "9. Get Job 2 Details"
curl -s http://localhost:4000/jobs/$JOB2_ID | jq
echo

echo "=== Test Complete ==="
```

Make it executable and run:

```bash
chmod +x test_api.sh
./test_api.sh
```

---

## Forking the Server

You can fork this server to create domain-specific applications. Here's an example:

### Creating a Music Server

```elixir
defmodule MyMusicServer.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Core capabilities — named queue + pool for music jobs
      {Core.Workers.JobQueue, name: MyMusicServer.Queue, pool: MyMusicServer.Pool},
      {Core.Workers.WorkerPool,
        name: MyMusicServer.Pool,
        worker: MyMusicServer.Worker,
        size: 4,
        queue: MyMusicServer.Queue},

      # Custom HTTP router with music-specific endpoints
      {Bandit,
        plug: MyMusicServer.Router,
        scheme: :http,
        port: 5000,
        http_2_options: [enabled: true]
      },

      # Add your domain-specific services
      MyMusicServer.Library,
      MyMusicServer.Player,
      MyMusicServer.Playlist
    ]

    opts = [strategy: :one_for_one, name: MyMusicServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Extending Worker Behavior

Create a custom worker module that overrides `perform_work/1`. It can run in a `WorkerPool` just like the default worker:

```elixir
defmodule MyMusicServer.Worker do
  use GenServer
  require Logger
  alias Core.Workers.JobQueue

  @poll_interval 1_000

  def start_link(opts) do
    worker_id = Keyword.get(opts, :id, 1)
    pool_name = Keyword.get(opts, :pool, Core.Workers.WorkerPool)
    name = :"#{pool_name}_Worker_#{worker_id}"
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    worker_id = Keyword.get(opts, :id, 1)
    queue = Keyword.get(opts, :queue, Core.Workers.JobQueue)
    Logger.info("Worker ##{worker_id} started")
    Process.send_after(self(), :work, @poll_interval)
    {:ok, %{id: worker_id, queue: queue}}
  end

  def handle_info(:work, state) do
    case JobQueue.claim_next(state.queue) do
      {:ok, job} -> execute(job, state)
      :empty -> :noop
    end
    Process.send_after(self(), :work, @poll_interval)
    {:noreply, state}
  end

  defp execute(job, %{id: worker_id, queue: queue}) do
    Logger.info("Worker ##{worker_id} executing job #{job.id}")

    try do
      result = perform_work(job)
      JobQueue.mark_done(queue, job.id, result)
      Logger.info("Worker ##{worker_id} completed job #{job.id}")
    rescue
      error ->
        Logger.error("Worker ##{worker_id} failed job #{job.id}: #{Exception.message(error)}")
        JobQueue.mark_failed(queue, job.id, %{error: Exception.message(error)})
    end
  end

  defp perform_work(job) do
    case job.payload do
      %{"task" => "transcode_audio", "file" => file} ->
        transcode_audio(file)

      %{"task" => "generate_waveform", "track_id" => id} ->
        generate_waveform(id)

      %{"task" => "sync_library"} ->
        sync_library()

      _ ->
        %{error: "Unknown task type"}
    end
  end

  defp transcode_audio(file) do
    # Custom audio processing logic
    %{status: "transcoded", output: "#{file}.mp3"}
  end
end
```

---

## Architecture Decisions

### Why GenServer for Job Queue?

- **Serialized Access**: Ensures thread-safe operations on the queue
- **State Management**: Natural fit for maintaining queue and job state
- **Supervision**: Automatic restart on crashes
- **Telemetry Integration**: Built-in metrics and monitoring
- **Retry Logic**: Centralized handling of exponential backoff and re-enqueueing

### Why Keep Jobs in Queue?

- **Full History**: All jobs remain queryable after completion
- **Simpler Design**: No need for separate storage (ETS, DB)
- **Atomic Updates**: GenServer calls ensure consistency
- **Debugging**: Easy to inspect entire job lifecycle

### Job Storage Structure

```elixir
%{
  queue: :queue.new(),     # Queue of job IDs (FIFO)
  jobs: %{                 # Map of job ID to Job struct
    123 => %Job{...},
    124 => %Job{...}
  }
}
```

This dual structure allows:
- Fast FIFO queue operations
- O(1) job lookup by ID
- In-place status updates
- Full job history retention

---

## Performance Considerations

### Current Limitations

- **In-Memory Only**: Jobs are lost on server restart
- **Polling Overhead**: Workers poll every second
- **No Job Priorities**: All jobs are processed FIFO

### Scaling Strategies

For production deployments, consider:

1. **Multiple Pipelines**: Define separate queues and worker pools for different job types (e.g. CPU-intensive vs I/O-intensive) so they don't block each other.
2. **Persistent Storage**: Add PostgreSQL or Redis for job persistence
3. **Job Cleanup**: Archive completed jobs after N days
4. **Priority Queue**: Implement job prioritization
5. **Distributed Queue**: Use RabbitMQ or Kafka for distributed systems

---

## Configuration

### Port Configuration

Edit `lib/elixir_server_core/application.ex`:

```elixir
port = System.get_env("PORT", "4000") |> String.to_integer()
```

Then run:
```bash
PORT=8080 mix run --no-halt
```

### Worker Poll Interval

Edit `lib/core/workers/worker.ex`:

```elixir
@poll_interval 500  # Poll every 500ms instead of 1000ms
```

---

## Observability

### Logging

The server logs key events:

```elixir
[info] Starting server on port 4000
[info] Worker started
[info] Executing job 123
[info] Job 123 completed successfully
[error] Job 124 failed: %ArgumentError{message: "invalid data"}
```

### Telemetry Events

The following telemetry events are emitted:

- `[:server, :http, :start]` - HTTP request started
- `[:server, :http, :stop]` - HTTP request completed
- `[:core, :job, :start]` - Job execution started
- `[:core, :job, :stop]` - Job execution completed
- `[:core, :job, :error]` - Job execution failed

### Adding Prometheus Integration

To expose metrics, add to your supervision tree:

```elixir
children = [
  # ... existing children
  {TelemetryMetricsPrometheus, 
    metrics: Core.Capability.Metrics.metrics()
  }
]
```

Then access metrics at `http://localhost:9568/metrics`

---

## Configuration Reference

| Option | Type | Default | Description |
|---|---|---|---|
| `:router` | module | `Core.HTTP.Router` | Plug router module |
| `:port` | integer | `4000` (or `PORT` env) | HTTP server port |
| `:ip` | tuple | `{0,0,0,0}` | Bind address |
| `:worker` | module | `Core.Workers.Worker` | Worker module for processing jobs |
| `:worker_pool_size` | integer | CPU cores | Number of concurrent workers |
| `:job_store` | module | `Core.JobStore.Memory` | Persistence backend |
| `:job_store_opts` | keyword | `[]` | Options passed to the store |
| `:start_http` | boolean | `true` | Start `Bandit` automatically |
| `:start_workers` | boolean | `true` | Start `WorkerPool` automatically |
| `:pipelines` | list | `nil` | List of independent queue+pool configs (see Multiple Worker Pipelines) |

Set `start_http: false` when integrating into an existing Phoenix application or when you want full control over the HTTP server.

### Storage Backend Notes

**SQLite throughput ceiling:** The built-in SQLite adapter opens a new connection for every operation. This is simple and stateless, but it caps throughput at roughly ~1,000 operations per second on a typical SSD. If you need higher throughput, implement a stateful `Core.JobStore` adapter that uses a connection pool (e.g., `DBConnection` with Postgrex) or keeps a single long-lived connection.

---

## Troubleshooting

### Server won't start

```bash
# Check if port is already in use
lsof -i :4000

# Kill existing process
kill -9 <PID>

# Or use a different port
PORT=4001 mix run --no-halt
```

### Jobs not processing

```bash
# Check if worker is running
curl http://localhost:4000/health

# View logs for errors
mix run --no-halt

# Verify job was submitted
curl http://localhost:4000/jobs | jq
```

### JSON encoding errors

Ensure all structs used in responses have `@derive Jason.Encoder`:

```elixir
defmodule MyStruct do
  @derive Jason.Encoder
  defstruct [:field1, :field2]
end
```

---

## Open Source and Contributions

This project is **fully open source** under the MIT License. Contributions are welcome in the form of:

* Adding metrics and instrumentation
* Building Prometheus + Grafana integration
* Implementing domain-specific servers (music, PDF, etc.)
* Adding persistent storage backends
* Improving documentation and tests
* Performance optimizations
* Security enhancements

### Contributing Guidelines

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes with tests
4. Run tests: `mix test`
5. Commit: `git commit -am 'Add my feature'`
6. Push: `git push origin feature/my-feature`
7. Open a Pull Request

---

## License

MIT License - see LICENSE file for details

---

## Maintainer

**DarynOngera**

For questions, issues, or feature requests, please open an issue on GitHub.

---

## Resources

- [Elixir Documentation](https://elixir-lang.org/docs.html)
- [Plug Documentation](https://hexdocs.pm/plug/)
- [GenServer Guide](https://elixir-lang.org/getting-started/mix-otp/genserver.html)
- [Telemetry Documentation](https://hexdocs.pm/telemetry/)
- [Jason Documentation](https://hexdocs.pm/jason/)

---

## Roadmap

Completed:
- [x] Worker pool for parallel processing
- [x] Job scheduling (cron-like)
- [x] Job retries with exponential backoff
- [x] SQLite persistence backend
- [x] Pluggable `Core.JobStore` behaviour for custom databases
- [x] Multiple independent job queues and worker pools

Planned:
- [ ] PostgreSQL persistence backend (via `Core.JobStore.SQL` + Postgrex)
- [ ] Job priorities
- [ ] Prometheus + Grafana integration
- [ ] Authentication and authorization
- [ ] Admin dashboard UI
- [ ] Docker and Kubernetes deployment guides
- [ ] Performance benchmarking suite
