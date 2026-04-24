# ElixirServerCore HTTP API Curl Tests

This Markdown file is derived from the uploaded ExUnit test file. It converts the router-level HTTP tests into manual `curl` checks.

## Prerequisites

Start the app first:

```bash
mix run --no-halt
```

Or, if you want an interactive shell with the app loaded:

```bash
iex -S mix run --no-halt
```

Set a base URL. Adjust the port if your server uses a different one.

```bash
export BASE_URL="http://localhost:4001"
```

Optional but recommended:

```bash
sudo apt install jq
```

---

## 1. Root Endpoint

### Request

```bash
curl -i "$BASE_URL/"
```

### Expected

- HTTP status: `200`
- Body: server/root response

---

## 2. Health Check

### Request

```bash
curl -i "$BASE_URL/health"
```

### Expected

- HTTP status: `200`
- JSON body contains:

```json
{
  "status": "OK"
}
```

### jq check

```bash
curl -s "$BASE_URL/health" | jq
```

---

## 3. Queue Stats

### Request

```bash
curl -i "$BASE_URL/stats"
```

### Expected

- HTTP status: `200`
- JSON body contains a `total` field

### jq check

```bash
curl -s "$BASE_URL/stats" | jq
```

---

## 4. Create Job - Valid Payload

### Request

```bash
curl -i -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"test"}}'
```

### Expected

- HTTP status: `202`
- JSON body contains an integer `job_id`

Example:

```json
{
  "job_id": 1
}
```

### Store created job id

```bash
JOB_ID=$(curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"get_by_id"}}' | jq -r '.job_id')

echo "$JOB_ID"
```

---

## 5. Create Job - Missing Payload

### Request

```bash
curl -i -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"wrong":"field"}'
```

### Expected

- HTTP status: `400`
- JSON body contains an `error` message mentioning `payload`

### jq check

```bash
curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"wrong":"field"}' | jq
```

---

## 6. Schedule Job

### Request

```bash
curl -X POST http://localhost:4000/jobs/schedule \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {
      "task": "send_email",
      "user_id": 101
    },
    "run_at": "2026-04-25T10:30:00Z"
  }'
```
---

## 7. List Jobs

Create a job first:

```bash
curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"list_test"}}' | jq
```

### Request

```bash
curl -i "$BASE_URL/jobs"
```

### Expected

- HTTP status: `200`
- JSON body is a list/array of jobs

### jq check

```bash
curl -s "$BASE_URL/jobs" | jq
```

---

## 8. List Jobs Filtered by Status

Create a queued job first:

```bash
curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"filter_test"}}' | jq
```

### Request

```bash
curl -i "$BASE_URL/jobs?status=queued"
```

### Expected

- HTTP status: `200`
- Every returned job has:

```json
{
  "status": "queued"
}
```

### jq check

```bash
curl -s "$BASE_URL/jobs?status=queued" | jq
```

### Validate all returned statuses

```bash
curl -s "$BASE_URL/jobs?status=queued" | jq 'all(.[]; .status == "queued")'
```

Expected output:

```text
true
```

---

## 9. List Jobs With Pagination

The test suite covers pagination at the `JobQueue.all/1` layer, and the router builds options from `page` and `per_page` query parameters. Use this to manually verify the HTTP query path.

Create several jobs:

```bash
for i in $(seq 1 10); do
  curl -s -X POST "$BASE_URL/jobs" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"i\":$i}}" > /dev/null
done
```

### Page 1

```bash
curl -s "$BASE_URL/jobs?page=1&per_page=5" | jq
```

### Page 2

```bash
curl -s "$BASE_URL/jobs?page=2&per_page=5" | jq
```

### Expected

- Each response should return at most `5` jobs.
- Page 1 and page 2 should not contain the same job IDs.

### Count check

```bash
curl -s "$BASE_URL/jobs?page=1&per_page=5" | jq 'length'
curl -s "$BASE_URL/jobs?page=2&per_page=5" | jq 'length'
```

---

## 10. Get Job by ID

Create a job and store its ID:

```bash
JOB_ID=$(curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"get_by_id"}}' | jq -r '.job_id')
```

### Request

```bash
curl -i "$BASE_URL/jobs/$JOB_ID"
```

### Expected

- HTTP status: `200`
- JSON body contains the same `id`

### jq check

```bash
curl -s "$BASE_URL/jobs/$JOB_ID" | jq
```

### Validate returned ID

```bash
curl -s "$BASE_URL/jobs/$JOB_ID" | jq --argjson id "$JOB_ID" '.id == $id'
```

Expected output:

```text
true
```

---

## 11. Get Unknown Job

### Request

```bash
curl -i "$BASE_URL/jobs/999999999"
```

### Expected

- HTTP status: `404`

---

## 12. Unknown Route

### Request

```bash
curl -i "$BASE_URL/not-a-route"
```

### Expected

- HTTP status: `404`

---

## Full Smoke Test Script

You can paste this into your terminal after starting the server.

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:4001}"

echo "== Root =="
curl -i "$BASE_URL/"

echo -e "\n== Health =="
curl -s "$BASE_URL/health" | jq

echo -e "\n== Stats =="
curl -s "$BASE_URL/stats" | jq

echo -e "\n== Create valid job =="
JOB_ID=$(curl -s -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"task":"smoke_test"}}' | jq -r '.job_id')
echo "Created job: $JOB_ID"

echo -e "\n== Create invalid job =="
curl -i -X POST "$BASE_URL/jobs" \
  -H "Content-Type: application/json" \
  -d '{"wrong":"field"}'

echo -e "\n== List jobs =="
curl -s "$BASE_URL/jobs" | jq

echo -e "\n== Filter queued jobs =="
curl -s "$BASE_URL/jobs?status=queued" | jq

echo -e "\n== Validate queued filter =="
curl -s "$BASE_URL/jobs?status=queued" | jq 'all(.[]; .status == "queued")'

echo -e "\n== Get job by ID =="
curl -s "$BASE_URL/jobs/$JOB_ID" | jq

echo -e "\n== Validate job ID =="
curl -s "$BASE_URL/jobs/$JOB_ID" | jq --argjson id "$JOB_ID" '.id == $id'

echo -e "\n== Unknown job =="
curl -i "$BASE_URL/jobs/999999999"

echo -e "\n== Unknown route =="
curl -i "$BASE_URL/not-a-route"
```

---

## Endpoint Summary

| Method | Endpoint | Purpose | Expected Status |
|---|---|---|---|
| `GET` | `/` | Root/server response | `200` |
| `GET` | `/health` | Health check | `200` |
| `GET` | `/stats` | Queue statistics | `200` |
| `POST` | `/jobs` | Create job | `202` |
| `POST` | `/jobs` with missing `payload` | Validate bad request handling | `400` |
| `POST` | `/jobs/schedule` | Schedule jobs | `200` |
| `GET` | `/jobs` | List jobs | `200` |
| `GET` | `/jobs?status=queued` | Filter jobs by status | `200` |
| `GET` | `/jobs?page=1&per_page=5` | Paginate jobs | `200` |
| `GET` | `/jobs/:id` | Get job by ID | `200` |
| `GET` | `/jobs/999999999` | Unknown job | `404` |
| `GET` | `/not-a-route` | Unknown route | `404` |
