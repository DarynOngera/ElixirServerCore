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

## Why ServCore?

Phoenix and Oban are excellent tools for full web applications. ServCore targets a narrower use case: standalone worker services that need only HTTP endpoints, a durable job queue, worker supervision, retries, scheduling, and basic observability.

Instead of assembling multiple libraries or adopting a larger framework than the problem requires, ServCore gives you a single, minimal foundation:

- **Bandit** for HTTP endpoints
- **OTP supervision trees** for fault tolerance
- **Background job queues** with worker pools
- **Exponential backoff retries**
- **Job scheduling**
- **Telemetry instrumentation**
- **Pluggable persistence**

Use in-memory storage for rapid prototyping, SQLite for lightweight durability, or implement the `Core.JobStore` behaviour to integrate with your preferred database.

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

*Elixir 1.14+ and Erlang/OTP 26+ required*

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

Then define routes explicitly in your router:

```elixir
import Core.HTTP.BaseRouter
alias Core.HTTP.Handlers

post "/email_jobs",        do: Handlers.create_job(conn, MyApp.EmailQueue)
post "/email_jobs/schedule", do: Handlers.schedule_job(conn, MyApp.EmailQueue)
get "/email_jobs",         do: Handlers.list_jobs(conn, MyApp.EmailQueue)
get "/email_jobs/:id",     do: Handlers.get_job(conn, id, MyApp.EmailQueue)

post "/media_jobs",        do: Handlers.create_job(conn, MyApp.MediaQueue)
post "/media_jobs/schedule", do: Handlers.schedule_job(conn, MyApp.MediaQueue)
get "/media_jobs",         do: Handlers.list_jobs(conn, MyApp.MediaQueue)
get "/media_jobs/:id",     do: Handlers.get_job(conn, id, MyApp.MediaQueue)

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

```bash
git clone https://github.com/DarynOngera/ServCore.git
cd servcore
mix deps.get
mix compile
mix run --no-halt
```

Then rename the app in `mix.exs` and edit `lib/core/` directly. See [FORKING.md](FORKING.md).

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

A job flows from HTTP submission through the queue to worker execution:

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

`JobQueue.submit/2` persists the job, assigns an ID, and wakes workers via `:work_available`. Workers claim jobs atomically through a `GenServer.call` to `claim_next/1`, execute `perform_work/1`, and report results via `mark_done/2` or `mark_failed/2`. Retries are scheduled with exponential backoff when attempts remain.

For the full deep dive on worker notification, claiming mechanics, and custom workers, see `ARCHITECTURE.md`.

---

## Project Structure

```text
servcore/
├── lib/
│   ├── core/
│   │   ├── http/
│   │   │   ├── router.ex              # HTTP routing and endpoints
│   │   │   ├── base_router.ex         # Macros for common routes (health, stats, root)
│   │   │   └── handlers.ex            # Request handler functions
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

### Custom Router

Define routes explicitly so you can pick which job endpoints to expose and wrap them with authentication or middleware:

```elixir
defmodule MyMusicServer.Router do
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  alias Core.HTTP.Handlers

  # Core routes — mount only the ones you need
  get "/" do
    send_resp(conn, 200, "Music Server is running")
  end

  post "/jobs" do
    Handlers.create_job(conn, MyMusicServer.Queue)
  end

  get "/jobs" do
    Handlers.list_jobs(conn, MyMusicServer.Queue)
  end

  get "/jobs/:id" do
    Handlers.get_job(conn, id, MyMusicServer.Queue)
  end

  # Music-specific routes
  get "/songs" do
    songs = MyMusicServer.Library.all_songs()
    send_resp(conn, 200, Jason.encode!(songs))
  end

  match _ do
    Handlers.send_json(conn, 404, %{error: "Not found"})
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

### Why Explicit Route Functions?

ServCore provides `Core.HTTP.Handlers` — plain functions that accept a `Plug.Conn` and return a `Plug.Conn` — instead of a monolithic `add_job_routes` macro. This gives you:

- **Composable routes**: Mount only the endpoints you need (`/jobs` but not `/jobs/schedule`, for example)
- **Middleware-friendly**: Wrap individual routes with authentication, rate limiting, or logging without abandoning the macro entirely
- **Single source of truth**: `Core.HTTP.Router` and your custom router both call the same handler functions, eliminating drift between implementations

Small macros like `add_health_route` and `add_stats_route` remain because they inject a single, stable route with no variation. Job routes are the opposite — the most likely thing a forking developer will want to customize.

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

- **Single GenServer bottleneck**: Each `JobQueue` serializes all operations (`submit`, `claim`, `mark_done`, `mark_failed`) through one process. A single queue caps throughput regardless of how many workers you add.
- **Polling overhead**: Each worker schedules a fallback `:work` timer every `@poll_interval` ms (default: 1,000 ms). An idle pool of 8 workers generates 8 timer messages per second even when the queue is empty. The `:work_available` wake-up mitigates this when jobs are flowing.
- **Head-of-line blocking**: All jobs in one queue are processed FIFO. A slow CPU-intensive job at the front delays faster I/O-bound jobs behind it.
- **In-memory growth**: Job structs accumulate in the `JobQueue` state map until cleanup runs (default: hourly, 7-day retention). High throughput means linear memory growth between cleanups.
- **SQLite throughput ceiling**: The built-in SQLite adapter opens a new connection per operation, capping throughput at roughly ~1,000 ops/sec. For higher throughput, implement a stateful `Core.JobStore` adapter using a connection pool.

### Throughput Expectations

| Backend | Typical throughput | Bottleneck |
|---|---|---|
| `Core.JobStore.Memory` | ~10,000+ ops/sec | Single GenServer message box |
| `Core.JobStore.SQLite` | ~1,000 ops/sec | Per-operation connection open/close |

### Worker Pool Sizing

Match `pool_size` to your bottleneck:

- **CPU-bound** (transcoding, rendering): size ≈ `System.schedulers_online()` to avoid contention.
- **I/O-bound** (HTTP calls, file uploads): size can be higher (8–32) since workers spend most time waiting.
- **Mixed workloads**: This is where **multiple pipelines** shine.

### Using Multiple Pipelines for Performance

If you have distinct job types with different resource profiles, define separate pipelines so they don't compete:

```elixir
config :servcore, pipelines: [
  [
    queue_name: MyApp.HeavyQueue,
    pool_name: MyApp.HeavyPool,
    worker: MyApp.VideoWorker,
    pool_size: System.schedulers_online(),   # CPU-bound, limited concurrency
    job_store: Core.JobStore.SQLite,
    job_store_opts: [database: "priv/heavy.db"]
  ],
  [
    queue_name: MyApp.LightQueue,
    pool_name: MyApp.LightPool,
    worker: MyApp.WebhookWorker,
    pool_size: 32,                             # I/O-bound, high concurrency
    job_store: Core.JobStore.SQLite,
    job_store_opts: [database: "priv/light.db"]
  ]
]
```

Benefits:
- **No head-of-line blocking**: A slow video transcode cannot delay a fast webhook dispatch.
- **Independent scaling**: Size each pool to match its workload without over-provisioning CPU workers.
- **Isolated failure**: A crash in the video worker pool does not stop webhook processing.
- **Per-queue stats**: Health checks and metrics report each pipeline separately.

For more scaling strategies — persistent storage adapters, connection pooling, job priorities, and distributed queues — see `SCALING.md`.

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

Planned:
- [ ] PostgreSQL persistence backend (via `Core.JobStore.SQL` + Postgrex)
- [ ] Job priorities
- [ ] Prometheus + Grafana integration
- [ ] Authentication and authorization
- [ ] Admin dashboard UI
- [ ] Docker and Kubernetes deployment guides
- [ ] Performance benchmarking suite
