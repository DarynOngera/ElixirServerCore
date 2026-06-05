import Config

config :servcore,
  worker_pool_size:
    String.to_integer(System.get_env("WORKER_POOL_SIZE", "#{System.schedulers_online()}"))

# Uncomment to enable Prometheus metrics endpoint
config :servcore, :telemetry_prometheus, port: 9568

# Uncomment to enable SQLite persistence for jobs across VM restarts.
# Requires `{:exqlite, "~> 0.29"}` in your mix.exs deps.
# config :servcore,
#   job_store: Core.JobStore.SQLite,
#   job_store_opts: [database: "priv/jobs.db"]
