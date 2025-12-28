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
* Background job queue and worker execution
* Observability via Telemetry
* Optional Prometheus + Grafana integration (not implemented)
* Health check endpoint
* Modular and extensible architecture

---

## High-Level Architecture
```
Client ──HTTP──▶ Router ──▶ OTP Supervision Tree
                               │
                               ├── Telemetry Events
                               │
                               ▼
                          /metrics (optional)  Prometheus → Grafana
```

---

## Project Structure
```text
elixir_server_core/
├── lib/
│   ├── core/
│   │   ├── http/
│   │   │   ├── router.ex         # HTTP routing
│   │   ├── workers/
│   │   │   ├── job.ex            # Job struct
│   │   │   ├── job_queue.ex      # Job queue logic
│   │   └── capability/           # Optional reusable capabilities
│   │       ├── http.ex
│   │       ├── work_queue.ex
│   │       └── metrics.ex
├── config/
├── test/
└── mix.exs
```

---

## Getting Started

### Requirements

* Elixir 1.15 or newer
* Erlang/OTP 26 or newer

---

### Setup
```bash
mix deps.get
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

---

## Available Endpoints

| Endpoint   | Purpose                                            |
| ---------- | -------------------------------------------------- |
| `/`        | Root endpoint                                      |
| `/health`  | Service health check                               |
| `/metrics` | Prometheus metrics (optional, not yet implemented) |

---

## Forking the Server

You can fork the server by creating a new Application module:
```elixir
defmodule MyMusicServer.Application do
  use Application

  def start(_type, _args) do
    children = [
      Core.Capability.HTTP.child_spec(5000),
      {Core.Capability.WorkQueue, []}
      # Add your domain-specific capabilities here
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Observability and job execution are built-in; you only add domain-specific logic.

---

## Open Source and Contributions

This project is **fully open source**. Contributions are welcome in the form of:

* Adding metrics and instrumentation
* Building Prometheus + Grafana integration
* Implementing domain-specific servers
* Improving documentation and tests

---

## License

MIT License

---

## Maintainer

DarynOngera
