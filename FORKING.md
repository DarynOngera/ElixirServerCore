# Forking Guide

This guide shows you how to create specialized servers (Music Server, PDF Server, etc.) using Elixir Server Core as a foundation.

---

## Overview

Elixir Server Core provides:
- [✓] Job queue with background workers
- [✓] HTTP server with REST API
- [✓] Telemetry and observability hooks
- [✓] OTP supervision for fault tolerance

You can fork this to create domain-specific servers by:
1. **Using as a library** (recommended for most cases)
2. **Forking the repository** (if you need to modify core functionality)

---

## Method 1: Using as a Library (Recommended)

This method lets you use Elixir Server Core as a dependency without modifying it.

### Step 1: Create a New Project

```bash
mix new my_music_server --sup
cd my_music_server
```

### Step 2: Add Elixir Server Core as Dependency

**Option A: From Hex (when published)**
```elixir
# mix.exs
defp deps do
  [
    {:elixir_server_core, "~> 0.1.0"}
  ]
end
```

**Option B: From Local Path (for development)**
```elixir
# mix.exs
defp deps do
  [
    {:elixir_server_core, path: "../elixir_server_core"}
  ]
end
```

**Option C: From Git**
```elixir
# mix.exs
defp deps do
  [
    {:elixir_server_core, git: "https://github.com/DarynOngera/ElixirServerCore/elixir_server_core.git"}
  ]
end
```

### Step 3: Create Your Custom Router

You have two approaches for creating a custom router:

#### Approach A: Using Helper Macros

```elixir
# lib/my_music_server/router.ex
defmodule MyMusicServer.Router do
  use Plug.Router
  require Logger

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

  # Import base route helpers
  import Core.HTTP.BaseRouter
  
  # Add standard routes from core
  add_root_route()
  add_health_route()
  add_job_routes()

  # Add your custom routes
  get "/songs" do
    songs = MyMusicServer.Library.all_songs()
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(songs))
  end
  
  get "/songs/:id" do
    case MyMusicServer.Library.get_song(id) do
      {:ok, song} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(song))
      
      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Song not found"}))
    end
  end
  
  post "/songs/:id/play" do
    case MyMusicServer.Player.play(id) do
      :ok ->
        send_resp(conn, 200, "Playing song #{id}")
      
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: reason}))
    end
  end
  
  post "/playlists" do
    case conn.body_params do
      %{"name" => name, "song_ids" => ids} ->
        {:ok, playlist} = MyMusicServer.PlaylistManager.create(name, ids)
        
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(playlist))
      
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid playlist data"}))
    end
  end
  
  # Catch-all (must be last)
  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
```

#### Approach B: Copy Routes Manually

Sometimes it's simpler to just copy the routes you need:

```elixir
# lib/my_music_server/router.ex
defmodule MyMusicServer.Router do
  use Plug.Router
  require Logger
  alias Core.Workers.JobQueue

  plug Plug.Logger, log: :info
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug Plug.Telemetry, event_prefix: [:server, :http]
  plug :dispatch

  # Copied from Core.HTTP.Router
  get "/" do
    send_resp(conn, 200, "Music Server is running")
  end

  get "/health" do
    worker_alive = Process.whereis(JobQueue) != nil
    status = if worker_alive, do: "OK", else: "DEGRADED"
    send_resp(conn, 200, status)
  end

  # Your custom routes...
  get "/songs" do
    # ...
  end
  
  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
```

### Step 4: Create Custom Worker (Optional)

If you need custom job processing logic:

```elixir
# lib/my_music_server/music_worker.ex
defmodule MyMusicServer.MusicWorker do
  use GenServer
  require Logger
  alias Core.Workers.JobQueue

  @poll_interval 1_000

  ## ============================================================
  ## Public API
  ## ============================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## ============================================================
  ## GenServer Callbacks
  ## ============================================================

  @impl true
  def init(state) do
    Logger.info("Music Worker started")
    schedule_work()
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    case JobQueue.claim_next() do
      {:ok, job} -> execute(job)
      :empty -> :noop
    end

    schedule_work()
    {:noreply, state}
  end

  ## ============================================================
  ## Private Functions
  ## ============================================================

  defp schedule_work do
    Process.send_after(self(), :work, @poll_interval)
  end

  defp execute(job) do
    Logger.info("Processing music job #{job.id}")
    
    try do
      result = case job.payload do
        %{"task" => "transcode_audio", "file" => file, "format" => format} ->
          transcode_audio(file, format)
        
        %{"task" => "generate_waveform", "song_id" => id} ->
          generate_waveform(id)
        
        %{"task" => "extract_metadata", "file" => file} ->
          extract_metadata(file)
        
        %{"task" => "sync_library"} ->
          sync_library()
        
        _ ->
          %{error: "Unknown task type"}
      end
      
      JobQueue.mark_done(job.id, result)
      Logger.info("Music job #{job.id} completed successfully")
    rescue
      error ->
        error_details = %{
          error: Exception.message(error),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        }
        
        Logger.error("Music job #{job.id} failed: #{inspect(error)}")
        JobQueue.mark_failed(job.id, error_details)
    end
  end

  defp transcode_audio(file, format) do
    # Your custom audio processing logic
    Logger.info("Transcoding #{file} to #{format}")
    Process.sleep(500)  # Simulate work
    
    %{
      status: "transcoded",
      input: file,
      output: "#{file}.#{format}",
      format: format
    }
  end
  
  defp generate_waveform(song_id) do
    # Your custom waveform generation logic
    Logger.info("Generating waveform for song #{song_id}")
    Process.sleep(300)  # Simulate work
    
    %{
      status: "generated",
      song_id: song_id,
      waveform_url: "/waveforms/#{song_id}.png"
    }
  end
  
  defp extract_metadata(file) do
    # Your custom metadata extraction
    Logger.info("Extracting metadata from #{file}")
    
    %{
      status: "extracted",
      title: "Song Title",
      artist: "Artist Name",
      album: "Album Name",
      duration: 240
    }
  end
  
  defp sync_library do
    # Your custom library sync logic
    Logger.info("Syncing music library")
    Process.sleep(1000)  # Simulate work
    
    %{
      status: "synced",
      songs_added: 15,
      songs_updated: 3,
      songs_removed: 1
    }
  end
end
```

### Step 5: Set Up Your Application

```elixir
# lib/my_music_server/application.ex
defmodule MyMusicServer.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "5000") |> String.to_integer()

    children = [
      # Core job queue (always needed)
      Core.Workers.JobQueue,
      
      # Your custom worker (or use Core.Workers.Worker)
      MyMusicServer.MusicWorker,
      
      # HTTP server with your custom router
      {Plug.Cowboy, 
        scheme: :http, 
        plug: MyMusicServer.Router, 
        options: [port: port, ip: {0, 0, 0, 0}]
      },
      
      # Your domain-specific services
      MyMusicServer.Library,
      MyMusicServer.Player,
      MyMusicServer.PlaylistManager
    ]

    Logger.info("Starting Music Server on port #{port}")
    Logger.info("http://localhost:#{port}")

    opts = [strategy: :one_for_one, name: MyMusicServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Step 6: Add Required Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:elixir_server_core, path: "../elixir_server_core"},
    {:plug_cowboy, "~> 2.7"},
    {:jason, "~> 1.4"},
    # Your domain-specific dependencies
    {:id3, "~> 1.0"}  # Example: MP3 metadata parsing
  ]
end
```

### Step 7: Run Your Server

```bash
mix deps.get
mix compile
mix run --no-halt
```

Your server is now running with:
- [✓] Job queue from core
- [✓] Custom routes for your domain
- [✓] Custom worker logic
- [✓] Your domain-specific services

---

## Method 2: Fork the Repository

Use this method if you need to modify core framework functionality.

### Step 1: Fork the Repository

```bash
git clone https://github.com/DarynOngera/elixir_server_core.git my_music_server
cd my_music_server

# Update remote
git remote rename origin upstream
git remote add origin https://github.com/yourusername/my_music_server.git
```

### Step 2: Rename the Project

```elixir
# mix.exs
defmodule MyMusicServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_music_server,  # Changed from :elixir_server_core
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyMusicServer.Application, []}  # Changed
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      # Add your deps here
    ]
  end
end
```

### Step 3: Modify Core Files

Now you can directly modify:
- `lib/core/workers/job_queue.ex` - Change queue behavior
- `lib/core/http/router.ex` - Modify base routes
- `lib/core/workers/worker.ex` - Change worker logic

### Step 4: Keep Core Updated (Optional)

To pull updates from the original core:

```bash
# Fetch upstream changes
git fetch upstream

# Merge into your fork
git merge upstream/main

# Resolve conflicts and commit
```

---

## Complete Example: Music Server

Here's a complete, working music server implementation:

### Project Structure

```
my_music_server/
├── lib/
│   ├── my_music_server/
│   │   ├── application.ex      # Supervision tree
│   │   ├── router.ex            # HTTP routes
│   │   ├── music_worker.ex      # Background jobs
│   │   ├── library.ex           # Song database
│   │   ├── player.ex            # Playback control
│   │   └── playlist_manager.ex  # Playlist logic
│   └── my_music_server.ex       # Module root
├── mix.exs
└── README.md
```

### Library Module

```elixir
# lib/my_music_server/library.ex
defmodule MyMusicServer.Library do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def all_songs do
    GenServer.call(__MODULE__, :all_songs)
  end

  def get_song(id) do
    GenServer.call(__MODULE__, {:get_song, id})
  end

  @impl true
  def init(_) do
    # Initialize with some sample data
    songs = %{
      "1" => %{id: "1", title: "Song One", artist: "Artist A", duration: 240},
      "2" => %{id: "2", title: "Song Two", artist: "Artist B", duration: 180},
      "3" => %{id: "3", title: "Song Three", artist: "Artist A", duration: 200}
    }
    {:ok, songs}
  end

  @impl true
  def handle_call(:all_songs, _from, songs) do
    {:reply, Map.values(songs), songs}
  end

  @impl true
  def handle_call({:get_song, id}, _from, songs) do
    case Map.get(songs, id) do
      nil -> {:reply, {:error, :not_found}, songs}
      song -> {:reply, {:ok, song}, songs}
    end
  end
end
```

### Player Module

```elixir
# lib/my_music_server/player.ex
defmodule MyMusicServer.Player do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{current: nil}, name: __MODULE__)
  end

  def play(song_id) do
    GenServer.call(__MODULE__, {:play, song_id})
  end

  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  def current do
    GenServer.call(__MODULE__, :current)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:play, song_id}, _from, state) do
    case MyMusicServer.Library.get_song(song_id) do
      {:ok, _song} ->
        {:reply, :ok, %{state | current: song_id}}
      
      {:error, :not_found} ->
        {:reply, {:error, "Song not found"}, state}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:reply, :ok, %{state | current: nil}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.current, state}
  end
end
```

### Playlist Manager

```elixir
# lib/my_music_server/playlist_manager.ex
defmodule MyMusicServer.PlaylistManager do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def create(name, song_ids) do
    GenServer.call(__MODULE__, {:create, name, song_ids})
  end

  def all do
    GenServer.call(__MODULE__, :all)
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:create, name, song_ids}, _from, playlists) do
    id = System.unique_integer([:positive]) |> Integer.to_string()
    playlist = %{
      id: id,
      name: name,
      song_ids: song_ids,
      created_at: DateTime.utc_now()
    }
    
    updated = Map.put(playlists, id, playlist)
    {:reply, {:ok, playlist}, updated}
  end

  @impl true
  def handle_call(:all, _from, playlists) do
    {:reply, Map.values(playlists), playlists}
  end
end
```

### Testing Your Music Server

```bash
# Start the server
mix run --no-halt

# In another terminal, test the API:

# Health check
curl http://localhost:5000/health

# Get all songs
curl http://localhost:5000/songs | jq

# Get specific song
curl http://localhost:5000/songs/1 | jq

# Play a song
curl -X POST http://localhost:5000/songs/1/play

# Create a playlist
curl -X POST http://localhost:5000/playlists \
  -H "Content-Type: application/json" \
  -d '{"name": "My Favorites", "song_ids": ["1", "3"]}'

# Submit a background job
curl -X POST http://localhost:5000/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": {"task": "transcode_audio", "file": "song.wav", "format": "mp3"}}'

# Check job status
curl http://localhost:5000/jobs | jq
```

---

## Tips and Best Practices

### 1. Use Core Components Selectively

You don't have to use everything. Pick what you need:

```elixir
# Minimal setup - just job queue
children = [
  Core.Workers.JobQueue,
  MyApp.CustomWorker
]

# No HTTP server needed if you're building a background processor
```

### 2. Override Default Worker Behavior

```elixir
# Use core queue but custom worker
children = [
  Core.Workers.JobQueue,
  MyApp.Worker  # Your implementation
]
```

### 3. Keep Core Logic Unchanged

When using as a library, you get automatic updates:

```bash
# Update core to latest version
mix deps.update elixir_server_core
```

### 4. Environment Configuration

```elixir
# config/config.exs
config :my_music_server,
  port: 5000,
  music_directory: "/path/to/music",
  worker_poll_interval: 1000

# In your application
port = Application.get_env(:my_music_server, :port)
```

### 5. Testing Your Fork

```elixir
# test/my_music_server_test.exs
defmodule MyMusicServerTest do
  use ExUnit.Case
  alias Core.Workers.JobQueue

  setup do
    {:ok, _} = Application.ensure_all_started(:my_music_server)
    :ok
  end

  test "submits audio processing job" do
    {:ok, id} = JobQueue.submit(%{
      "task" => "transcode_audio",
      "file" => "test.wav",
      "format" => "mp3"
    })
    
    assert is_integer(id)
    
    # Wait for processing
    :timer.sleep(2000)
    
    {:ok, job} = JobQueue.get(id)
    assert job.status == :done
    assert job.result["status"] == "transcoded"
  end
end
```

---

## Troubleshooting

### Issue: Can't find Core modules

**Problem:** `Core.Workers.JobQueue` is undefined

**Solution:** Make sure you added the dependency and ran:
```bash
mix deps.get
```

### Issue: Port already in use

**Solution:**
```bash
PORT=5001 mix run --no-halt
```

### Issue: Jobs not processing

**Check:**
1. Worker is started in supervision tree
2. JobQueue is started before Worker
3. Check logs for errors

### Issue: Routes not working

**Check:**
1. Router is passed to Plug.Cowboy correctly
2. Routes are defined before `match _` catch-all
3. Plugs are in correct order

---

## Next Steps

1. **Add persistence**: Store jobs/data in PostgreSQL
2. **Add authentication**: Secure your API endpoints
3. **Add WebSockets**: Real-time updates for job progress
4. **Add metrics**: Monitor performance with Prometheus
5. **Deploy**: Containerize with Docker

---

## Support

- [Core Documentation](/README.md)
- [Report Issues](https://github.com/DarynOngera/ElixirServerCore/issues)
- [Discussions](https://github.com/DarynOngera/ElixirServerCore/discussions)

---

## License

MIT License - Fork freely!
