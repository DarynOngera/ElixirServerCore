import Config

config :servcore,
  worker_pool_size:
    String.to_integer(System.get_env("WORKER_POOL_SIZE", "#{System.schedulers_online()}")),
  max_age_days: 7

# Uncomment to enable SQLite persistence for jobs across VM restarts.
# Requires `{:exqlite, "~> 0.29"}` in your mix.exs deps.
# config :servcore,
#   job_store: Core.JobStore.SQLite,
#   job_store_opts: [database: "priv/jobs.db"]

import_config "#{config_env()}.exs"
