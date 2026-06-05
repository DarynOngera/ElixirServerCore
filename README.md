# Elixir Server Core

**Build small, durable background-processing services in Elixir without Phoenix or Oban.**

Elixir Server Core is a minimal, forkable toolkit for background-job services. It gives you HTTP endpoints, supervised workers, pluggable job persistence, and observability — the primitives you actually need, without the parts you don't.

**Typical use cases:**

- **Specialized worker services** — media transcoding, PDF processing, webhook ingestion
- **Single-node deployments** — SQLite-backed durability on a small VPS or embedded device
- **Learning OTP** — assemble a production system from GenServer, Supervisors, and Behaviours
- **Forking** — clone, swap in your domain logic, and ship

**The problem:** Background-processing services in Elixir usually pull in Phoenix or Oban. That's overkill when you just need an HTTP entry point, a job queue, retries, and maybe a SQLite file for durability across restarts.

**The solution:** Fork this repo or add it as a dependency. Configure your router and worker module. The core handles the rest — HTTP via Plug + Cowboy, job lifecycle via OTP supervision, exponential backoff retries, and Telemetry. Storage is pluggable: in-memory for prototyping, SQLite for single-node durability, or any SQL database via the `Core.JobStore` behaviour.

---

## Features

* Forkable server framework for domain-specific services
* HTTP server using Plug + Cowboy
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
{:elixir_server_core, "~> 0.1"}

# config/config.exs
config :elixir_server_core,
  router: MyApp.Router,
  port: 4000,
  job_store: Core.JobStore.SQLite,
  job_store_opts: [database: "priv/jobs.db"]
```

The framework auto-starts `JobQueue`, `WorkerPool`, and `Plug.Cowboy` with your router.

### Manual Supervision (library, full control)

```elixir
# config/config.exs
config :elixir_server_core, start_http: false

# application.ex
children = [
  {Core.Workers.JobQueue, store: Core.JobStore.SQLite, store_opts: [database: "jobs.db"]},
  {Core.Workers.WorkerPool, worker: MyApp.Worker, size: 4},
  {Plug.Cowboy, scheme: :http, plug: MyApp.Router, options: [port: 4000]}
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

## Project Structure

```text
elixir_server_core/
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
git clone <repository-url>
cd elixir_server_core

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
      # Core capabilities
      Core.Workers.JobQueue,
      Core.Workers.Worker,
      
      # Custom HTTP router with music-specific endpoints
      {Plug.Cowboy, 
        scheme: :http, 
        plug: MyMusicServer.Router, 
        options: [port: 5000]
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

Override the `perform_work/1` function to add custom job handling:

```elixir
defmodule MyMusicServer.Worker do
  use GenServer
  alias Core.Workers.JobQueue

  # ... (same setup as Core.Workers.Worker)

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
  
  # ... more custom handlers
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

1. **Persistent Storage**: Add PostgreSQL or Redis for job persistence
2. **Job Cleanup**: Archive completed jobs after N days
3. **Priority Queue**: Implement job prioritization
4. **Distributed Queue**: Use RabbitMQ or Kafka for distributed systems

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
| `:start_http` | boolean | `true` | Start `Plug.Cowboy` automatically |
| `:start_workers` | boolean | `true` | Start `WorkerPool` automatically |

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

Planned:
- [ ] PostgreSQL persistence backend (via `Core.JobStore.SQL` + Postgrex)
- [ ] Job priorities
- [ ] Prometheus + Grafana integration
- [ ] Authentication and authorization
- [ ] Admin dashboard UI
- [ ] Docker and Kubernetes deployment guides
- [ ] Performance benchmarking suite
