defmodule Core.Capability.HTTP do
  use Plug.Router
  require Logger

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

  get "/" do
    send_resp(conn, 200, "Server is running")
  end

  get "/health" do
    send_resp(conn, 200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  def child_spec(port \\ 4000) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: __MODULE__,
      options: [port: port]
    )
  end
end

