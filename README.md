**This is not the top level of the project, regards.**
# Elixir Server Core

An **open-source, production-oriented Elixir HTTP server framework** designed with **reliability, observability, and modular architecture** as first-class concerns. This framework can be forked to create specialized servers, such as Music servers, PDF servers, or custom domain-specific services.

At its core, the system leverages **Elixir and OTP supervision trees** to ensure fault isolation and automatic recovery from failures. Application components such as the HTTP server and background workers are supervised independently, allowing the system to remain available even when individual processes crash.

Observability is designed into the framework, with **Telemetry** instrumentation for request and job events. Metrics can optionally be exposed via **Prometheus** and visualized using **Grafana** (integration not yet implemented), providing a foundation for real-time operational insight in forked servers.

The framework emphasizes clarity over abstraction, avoiding unnecessary dependencies while adhering to backend best practices. Its modular design allows extension into specialized servers, distributed systems, alerting pipelines, or containerized deployments.

---

## Features

* Forkable server framework for domain-specific services
* HTTP server using Plug + Cowboy
* OTP supervision trees for fault tolerance
* Background job queue with automatic worker execution
* In-memory job tracking with full lifecycle management
* Observability via Telemetry
* Optional Prometheus + Grafana integration (not implemented)
* RESTful API with JSON support
* Health check endpoint
* Modular and extensible architecture

---

## High-Level Architecture

```
Client ──HTTP──▶ Router ──▶ OTP Supervision Tree
                               │
                               ├── JobQueue (GenServer)
                               │   ├── Queue: Job IDs
                               │   └── Jobs: Job Data Map
                               │
                               ├── Worker (GenServer)
                               │   └── Polls & Executes Jobs
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

Jobs remain in the queue throughout their lifecycle, allowing you to track their complete history and status via the API. The worker polls the queue every second, claims the next available job, executes it, and updates its status accordingly.

---

## Project Structure

```text
elixir_server_core/
├── lib/
│   ├── core/
│   │   ├── http/
│   │   │   └── router.ex              # HTTP routing and endpoints
│   │   ├── workers/
│   │   │   ├── job.ex                 # Job struct definition
│   │   │   ├── job_queue.ex           # Job queue GenServer
│   │   │   └── worker.ex              # Background job worker
│   │   └── capability/                # Optional reusable capabilities
│   │       ├── http.ex                # Alternative HTTP capability
│   │       ├── work_queue.ex          # Work queue capability
│   │       ├── metrics.ex             # Telemetry metrics definitions
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

| Method | Endpoint       | Description                          |
|--------|---------------|--------------------------------------|
| GET    | `/`           | Root endpoint - server status        |
| GET    | `/health`     | Health check                         |
| POST   | `/jobs`       | Submit a new job                     |
| GET    | `/jobs`       | List all jobs                        |
| GET    | `/jobs/:id`   | Get a specific job by ID             |

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
```
OK
```

If the JobQueue process is not running, returns:
```
DEGRADED
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
```

---

#### `GET /jobs` - List All Jobs

Returns all jobs in the queue with their current status.

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

**Filter by Status (using jq):**
```bash
# Show only completed jobs
curl -s http://localhost:4000/jobs | jq '[.[] | select(.status == "done")]'

# Show only running jobs
curl -s http://localhost:4000/jobs | jq '[.[] | select(.status == "running")]'

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

# Submit job 3
curl -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "generate_reports"}}'
```

### 2. Monitor Job Progress

```bash
# List all jobs
curl http://localhost:4000/jobs | jq

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
curl -s http://localhost:4000/health
echo -e "\n"

echo "2. Submit Job 1"
JOB1=$(curl -s -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "test_job_1"}}')
echo $JOB1 | jq
JOB1_ID=$(echo $JOB1 | jq -r '.job_id')
echo

echo "3. Submit Job 2"
JOB2=$(curl -s -X POST http://localhost:4000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "test_job_2", "priority": "high"}}')
echo $JOB2 | jq
JOB2_ID=$(echo $JOB2 | jq -r '.job_id')
echo

echo "4. Wait for processing..."
sleep 2
echo

echo "5. Get All Jobs"
curl -s http://localhost:4000/jobs | jq
echo

echo "6. Get Job 1 Details"
curl -s http://localhost:4000/jobs/$JOB1_ID | jq
echo

echo "7. Get Job 2 Details"
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
- **Telemetry Integration**: Easy to add metrics and monitoring

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
- **No Pagination**: `/jobs` endpoint returns all jobs
- **Single Worker**: Only one job processes at a time
- **Polling Overhead**: Worker polls every second

### Scaling Strategies

For production deployments, consider:

1. **Persistent Storage**: Add PostgreSQL or Redis for job persistence
2. **Multiple Workers**: Spawn worker pool for parallel processing
3. **Pagination**: Add query parameters to `/jobs` endpoint
4. **Job Cleanup**: Archive completed jobs after N days
5. **Priority Queue**: Implement job prioritization
6. **Distributed Queue**: Use RabbitMQ or Kafka for distributed systems

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
- `[:core, :job, :start]` - Job execution started (not yet implemented)
- `[:core, :job, :stop]` - Job execution completed (not yet implemented)
- `[:core, :job, :error]` - Job execution failed (not yet implemented)

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

- [ ] Add persistent storage backend (PostgreSQL)
- [ ] Implement job priorities
- [ ] Add worker pool for parallel processing
- [ ] Build Prometheus integration
- [ ] Add job scheduling (cron-like)
- [ ] Implement job retries with exponential backoff
- [ ] Add authentication and authorization
- [ ] Create admin dashboard UI
- [ ] Docker and Kubernetes deployment guides
- [ ] Performance benchmarking suite
