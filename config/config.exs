import Config

config :elixir_server_core,
  worker_pool_size: String.to_integer(System.get_env("WORKER_POOL_SIZE", "#{System.schedulers_online()}"))

# Uncomment to enable Prometheus metrics endpoint
config :elixir_server_core, :telemetry_prometheus, port: 9568
