defmodule LeaxerCore.Application do
  @moduledoc """
  Main OTP application module for LeaxerCore.

  ## Supervision Tree

  Uses `:one_for_one` strategy - if a child process terminates, only that process
  is restarted. This is appropriate because most services are independent.

  ### Process Start Order and Dependencies

  Children are started in order; later processes may depend on earlier ones:

  1. **LeaxerCoreWeb.Telemetry** - Metrics collection (independent)
  2. **DNSCluster** - DNS-based clustering (independent)
  3. **Phoenix.PubSub** - Message broadcasting backbone (required by most services)
  4. **LeaxerCore.LogBroadcaster** - Log streaming (depends on PubSub)
  5. **LeaxerCore.Nodes.Registry** - Node type registry via ETS (required by Runtime)
  6. **LeaxerCore.Models.Registry** - Model metadata cache (independent)
  7. **Task.Supervisor** - Async task execution (used by DownloadManager)
  8. **Finch** - HTTP client pool (used by DownloadManager)
  9. **LeaxerCore.Models.DownloadManager** - Model downloads (depends on Finch, PubSub)
  10. **LeaxerCore.HardwareMonitor** - System metrics (depends on PubSub)
  11. **LeaxerCore.Workers.ProcessTracker** - Orphaned process cleanup (independent)
  12. **LeaxerCore.ExecutionState** - Execution progress via ETS (independent)
  13. **LeaxerCore.Queue** - Job queue manager (depends on PubSub, Runtime)
  14. **LeaxerCore.Workers.StableDiffusion** - CLI-based image generation (depends on ProcessTracker)
  15. **LeaxerCore.Workers.StableDiffusionServer** - Singleton HTTP server mode (keeps model in VRAM)
  16. **LeaxerCore.Workers.LLM** - Text generation via llama.cpp (depends on ProcessTracker)
  17. **LeaxerCoreWeb.Endpoint** - Phoenix HTTP/WebSocket server (depends on PubSub)

  ### Restart Behavior

  With `:one_for_one`, each process restarts independently:

  - **ETS-backed services** (Registry, ExecutionState, Queue): State survives restarts
    since ETS tables are owned by the supervisor, not the GenServer.
  - **Stateless workers** (StableDiffusion, LLM): Clean restart, any in-flight job fails.
  - **External process managers** (StableDiffusion, LLM, StableDiffusionServer):
    On crash, ProcessTracker detects via monitor and kills orphaned OS processes.
  - **StableDiffusionServer**: Singleton HTTP server that keeps model in VRAM. On crash,
    ProcessTracker kills orphaned sd-server process; model reloads on next request.

  ### Failure Scenarios

  | Process Crash | Impact | Recovery |
  |--------------|--------|----------|
  | PubSub | All real-time updates stop | Auto-restart, clients reconnect |
  | Nodes.Registry | Node lookups fail | Auto-restart, ETS persists |
  | Queue | Job processing stops | Auto-restart, ETS state preserved |
  | StableDiffusion | Current generation fails | Auto-restart, ProcessTracker kills orphan |
  | ProcessTracker | Orphan detection stops | Auto-restart, re-scans for orphans |
  | Endpoint | All HTTP/WS connections drop | Auto-restart, clients reconnect |
  """

  use Application

  @impl true
  def start(_type, _args) do
    # On Windows, add priv/bin to PATH so child processes can find DLLs
    # This is needed because llama.cpp binaries dynamically link to CUDA DLLs
    setup_dll_path()

    # Ensure user directories exist
    LeaxerCore.Paths.ensure_directories!()

    # Initialize ETS table for stateful nodes (Counter, RoundRobin, etc.)
    :ets.new(:node_state, [:set, :public, :named_table])

    children = [
      LeaxerCoreWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:leaxer_core, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LeaxerCore.PubSub},
      # Compute backend detection and configuration (cached)
      LeaxerCore.ComputeBackend,
      # Log broadcaster (attaches to :logger)
      LeaxerCore.LogBroadcaster,
      # Node registry (ETS-based, must start before runtime)
      LeaxerCore.Nodes.Registry,
      # Model registry (remote models cache)
      LeaxerCore.Models.Registry,
      # Task supervisor for async operations (downloads, etc.)
      {Task.Supervisor, name: LeaxerCore.TaskSupervisor},
      # HTTP client for downloads
      {Finch, name: LeaxerCore.Finch},
      # Model download manager
      LeaxerCore.Models.DownloadManager,
      # Hardware monitoring (CPU, GPU, RAM, VRAM)
      LeaxerCore.HardwareMonitor,
      # Tmp directory cleanup (prevents disk from filling up)
      LeaxerCore.Cleanup.TmpCleaner,
      # Process tracker for orphaned external process cleanup
      LeaxerCore.Workers.ProcessTracker,
      # Execution state for progress persistence
      LeaxerCore.ExecutionState,
      # Job queue manager
      {LeaxerCore.Queue,
       batching_enabled:
         Application.get_env(:leaxer_core, LeaxerCore.Queue)[:batching_enabled] || true},
      # C++ inference workers
      LeaxerCore.Workers.StableDiffusion,
      # Singleton StableDiffusionServer for HTTP server mode (keeps model in VRAM)
      LeaxerCore.Workers.StableDiffusionServer,
      LeaxerCore.Workers.LLM,
      # LLMServer for persistent llama-server process (chat mode model warming)
      LeaxerCore.Workers.LLMServer,
      # Start to serve requests, typically the last entry
      LeaxerCoreWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LeaxerCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LeaxerCoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Add priv/bin to PATH on Windows so spawned processes can find DLLs
  defp setup_dll_path do
    case :os.type() do
      {:win32, _} ->
        bin_dir = LeaxerCore.BinaryFinder.priv_bin_dir()
        current_path = System.get_env("PATH") || ""

        unless String.contains?(current_path, bin_dir) do
          System.put_env("PATH", "#{bin_dir};#{current_path}")
        end

      _ ->
        :ok
    end
  end
end
