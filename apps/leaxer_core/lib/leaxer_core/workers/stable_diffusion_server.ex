defmodule LeaxerCore.Workers.StableDiffusionServer do
  @moduledoc """
  Singleton GenServer worker that manages a persistent sd-server process.

  Unlike the CLI-based StableDiffusion worker, this keeps the model loaded
  in memory between generations, significantly reducing time for consecutive
  jobs using the same model.

  ## Architecture

  This is a singleton GenServer registered as `__MODULE__`. It manages a single
  sd-server process on the default port (1234).

  ## Supervision

  - **Restart**: Permanent (always restarted)
  - **Strategy**: Part of main supervision tree with `:one_for_one`
  - **Persistent server**: Model stays loaded between generations

  ## Failure Modes

  - **Server process crash**: Port receives `{:exit_status, code}`, pending
    requests fail with error, state resets. Next request restarts server.
  - **GenServer crash**: sd-server OS process becomes orphaned on the port.
    ProcessTracker detects and kills orphan. Supervisor restarts GenServer.
  - **HTTP timeout**: Generation request fails, server may still be running.
    Next request verifies HTTP connectivity before proceeding.
  - **Server unresponsive**: `verify_http_connectivity/1` detects and triggers restart.

  ## State Recovery

  On restart:
  - ProcessTracker kills orphaned sd-server process
  - Model must be reloaded on first generation request
  - Pending requests from before crash are lost

  ## Requirements

  The sd-server binary must be present in `priv/bin/` with platform-specific names:
  - `sd-server-aarch64-apple-darwin` (macOS ARM)
  - `sd-server-x86_64-apple-darwin` (macOS Intel)
  - `sd-server-x86_64-unknown-linux-gnu` (Linux)
  - `sd-server-x86_64-pc-windows-msvc.exe` (Windows)

  If the server binary is not available, falls back to CLI mode via StableDiffusion worker.
  """

  use GenServer
  require Logger

  alias LeaxerCore.Workers.GenerationHelpers

  # Configuration
  @default_server_port 1234
  @request_timeout 600_000

  # Progress regex for sd-server format: |==>                 | 1/20 - 5.26it/s
  @progress_regex ~r/\|[=>\s]+\|\s*(\d+)\/(\d+)/

  defstruct [
    :port,
    :os_pid,
    :current_model,
    :compute_backend,
    :server_ready,
    :server_port,
    # {from, node_id, job_id, task_ref}
    :current_request,
    :start_time,
    pending_requests: [],
    starting: false,
    # Startup parameters that require server restart when changed
    startup_params: %{}
  ]

  # Parameters that require server restart when changed (CLI args)
  # Note: control_image is NOT here because it's per-request, not startup
  @startup_param_keys [
    :vae,
    :vae_tiling,
    :vae_on_cpu,
    :control_net,
    :control_net_cpu,
    :clip_l,
    :clip_g,
    :t5xxl,
    :clip_on_cpu,
    :photo_maker,
    :taesd
  ]

  # Extract startup parameters from opts that require server restart when changed
  defp extract_startup_params(opts) do
    @startup_param_keys
    |> Enum.map(fn key -> {key, Keyword.get(opts, key)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Check if startup parameters differ from current state
  defp startup_params_changed?(new_params, current_params) do
    # Only compare keys that are present in new_params
    # If new_params has a key that current doesn't, or values differ, restart needed
    Enum.any?(new_params, fn {key, new_value} ->
      current_value = Map.get(current_params, key)
      new_value != current_value
    end)
  end

  # Create a fresh state with explicit defaults to avoid any stale values
  defp fresh_state(server_port) do
    %__MODULE__{
      port: nil,
      os_pid: nil,
      current_model: nil,
      compute_backend: nil,
      server_ready: false,
      server_port: server_port,
      current_request: nil,
      start_time: nil,
      pending_requests: [],
      starting: false,
      startup_params: %{}
    }
  end

  # Client API

  @doc """
  Start the singleton StableDiffusionServer.

  ## Options

  - `:server_port` - The port to use (default: 1234)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate an image using the persistent sd-server.

  If the model differs from the currently loaded one, the server will restart
  with the new model (this takes time). Otherwise, generation is fast as the
  model is already in memory.

  ## Options

  - `:model` - Path to the model file (required)
  - `:compute_backend` - Backend to use: "cpu", "cuda", "metal" (default: "cpu")
  - All other options are passed to the generation request
  """
  def generate(prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @request_timeout)
    GenServer.call(__MODULE__, {:generate, prompt, opts}, timeout)
  catch
    :exit, {:noproc, _} ->
      {:error, "StableDiffusionServer not running"}
  end

  @doc """
  Check if the server is ready to accept requests.
  """
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, {:noproc, _} -> false
  end

  @doc """
  Check if server mode is available (binary exists).

  This is a static check - doesn't require a running instance.
  """
  def available? do
    cpu_path = server_executable_path("cpu")
    cuda_path = server_executable_path("cuda")

    cpu_exists = File.exists?(cpu_path)
    cuda_exists = File.exists?(cuda_path)
    metal_exists = server_binary_exists?("metal")

    Logger.debug(
      "[sd-server] Checking availability: cpu=#{cpu_exists}, cuda=#{cuda_exists}, metal=#{metal_exists}"
    )

    cpu_exists or cuda_exists or metal_exists
  end

  @doc """
  Get the currently loaded model.
  """
  def current_model do
    GenServer.call(__MODULE__, :current_model)
  catch
    :exit, {:noproc, _} -> nil
  end

  @doc """
  Abort the current generation (if any).
  """
  def abort do
    GenServer.cast(__MODULE__, :abort)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Stop the server and free VRAM.
  The server will automatically restart on the next generation request.
  """
  def stop_server do
    GenServer.cast(__MODULE__, :stop_server)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Stop the server synchronously and wait for completion.
  Returns :ok when the server is stopped and state is reset.
  """
  def stop_server_sync do
    GenServer.call(__MODULE__, :stop_server_sync, 10_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:timeout, _} -> :ok
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    server_port = Keyword.get(opts, :server_port, @default_server_port)
    Logger.info("[sd-server:#{server_port}] Instance initialized")

    state = %__MODULE__{
      server_ready: false,
      starting: false,
      server_port: server_port
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:generate, prompt, opts}, from, state) do
    model = Keyword.fetch!(opts, :model)
    requested_backend = Keyword.get(opts, :compute_backend) || detect_compute_backend()
    # This instance is bound to its port - ignore any server_port in opts
    server_port = state.server_port

    # Extract startup parameters that require server restart when changed
    new_startup_params = extract_startup_params(opts)
    startup_changed = startup_params_changed?(new_startup_params, state.startup_params)

    # Find an available backend - try requested first, then fallbacks
    compute_backend = find_available_backend(requested_backend)

    cond do
      # No server binary available for any backend - fall back to CLI
      is_nil(compute_backend) ->
        Logger.info(
          "[sd-server:#{server_port}] No server binary found for any backend, falling back to CLI mode"
        )

        result = LeaxerCore.Workers.StableDiffusion.generate(prompt, opts)
        {:reply, result, state}

      # Server ready with same model but startup params changed - need restart
      state.server_ready and state.current_model == model and startup_changed ->
        Logger.info("[sd-server:#{server_port}] Startup parameters changed, restarting server...")
        Logger.debug("[sd-server:#{server_port}] Old params: #{inspect(state.startup_params)}")
        Logger.debug("[sd-server:#{server_port}] New params: #{inspect(new_startup_params)}")

        # Stop existing server and restart with new params
        if state.port, do: stop_server_process(state)

        new_state = start_server_process(model, compute_backend, server_port, new_startup_params)
        pending = [{from, prompt, opts} | new_state.pending_requests]
        {:noreply, %{new_state | pending_requests: pending}}

      # Server ready with same model and same params - verify it's alive, then send request
      state.server_ready and state.current_model == model ->
        Logger.info(
          "[sd-server:#{server_port}] Model #{Path.basename(model)} already loaded, verifying server is alive..."
        )

        case verify_http_connectivity(server_port) do
          :ok ->
            Logger.info("[sd-server:#{server_port}] Server alive, sending request")
            send(self(), {:process_request, from, prompt, opts})
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "[sd-server:#{server_port}] Server not responding (#{inspect(reason)}), restarting..."
            )

            # Server died - restart it
            if state.port, do: stop_server_process(state)

            new_state =
              start_server_process(model, compute_backend, server_port, new_startup_params)

            pending = [{from, prompt, opts} | new_state.pending_requests]
            {:noreply, %{new_state | pending_requests: pending}}
        end

      # Server starting - queue the request
      state.starting ->
        Logger.info("[sd-server:#{server_port}] Server starting, queuing request")
        pending = [{from, prompt, opts} | state.pending_requests]
        {:noreply, %{state | pending_requests: pending}}

      # Need to start/restart server with new model
      true ->
        Logger.info(
          "[sd-server:#{server_port}] Starting server with model: #{Path.basename(model)}"
        )

        # Stop existing server if running
        if state.port, do: stop_server_process(state)

        new_state = start_server_process(model, compute_backend, server_port, new_startup_params)
        pending = [{from, prompt, opts} | new_state.pending_requests]
        {:noreply, %{new_state | pending_requests: pending}}
    end
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.server_ready, state}
  end

  def handle_call(:current_model, _from, state) do
    {:reply, state.current_model, state}
  end

  def handle_call(:stop_server_sync, _from, state) do
    if state.port do
      Logger.info("[sd-server:#{state.server_port}] Stopping server synchronously to free VRAM")
      stop_server_process(state)
      # Give the OS time to release resources
      Process.sleep(100)
    end

    # Reset to clean state
    {:reply, :ok, fresh_state(state.server_port)}
  end

  @impl true
  def handle_cast(:abort, state) do
    Logger.info(
      "[sd-server:#{state.server_port}] Abort requested - killing server to stop generation"
    )

    # Reply to current request with abort error
    case state.current_request do
      {from, _node_id, _job_id, task_ref} ->
        # Demonitor and flush the task - we'll ignore its result
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, {:error, "Generation aborted by user"})

      _ ->
        :ok
    end

    # Reply to any pending requests with abort error
    Enum.each(state.pending_requests, fn {from, _prompt, _opts} ->
      GenServer.reply(from, {:error, "Generation aborted by user"})
    end)

    # Kill the sd-server OS process to immediately stop generation
    # This is the only way to truly abort since sd-server has no cancel API
    if state.os_pid do
      Logger.info("[sd-server:#{state.server_port}] Killing sd-server process #{state.os_pid}")
      stop_server_process(state)
    end

    # Reset to a completely clean state - next request will start fresh
    {:noreply, fresh_state(state.server_port)}
  end

  def handle_cast(:stop_server, state) do
    if state.port do
      Logger.info("[sd-server:#{state.server_port}] Stopping server to free VRAM")
      stop_server_process(state)
    end

    # Reset to clean state
    {:noreply, fresh_state(state.server_port)}
  end

  @impl true
  def handle_info({:process_request, from, prompt, opts}, state) do
    # Extract node_id and job_id for progress tracking
    node_id = Keyword.get(opts, :node_id)
    job_id = Keyword.get(opts, :job_id)
    server_port = state.server_port || @default_server_port

    # Verify HTTP connectivity before sending generation request
    case verify_http_connectivity(server_port) do
      :ok ->
        Logger.info(
          "[sd-server:#{server_port}] HTTP connectivity verified, starting generation task"
        )

        # Run HTTP request in a Task so we can continue receiving port messages
        task =
          Task.async(fn ->
            send_generation_request(prompt, opts, server_port)
          end)

        new_state = %{state | current_request: {from, node_id, job_id, task.ref}}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "[sd-server:#{server_port}] HTTP connectivity check failed: #{inspect(reason)}"
        )

        Logger.warning(
          "[sd-server:#{server_port}] Server appears dead, resetting state to force restart on next request"
        )

        # Kill any zombie process
        if state.os_pid do
          stop_server_process(state)
        end

        GenServer.reply(from, {:error, "Server not responding to HTTP: #{inspect(reason)}"})
        # Reset state so next request will restart the server
        {:noreply, %__MODULE__{server_ready: false, starting: false, server_port: server_port}}
    end
  end

  # Handle async task result
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Demonitor and flush the DOWN message
    Process.demonitor(ref, [:flush])

    case state.current_request do
      {from, _node_id, _job_id, ^ref} ->
        GenServer.reply(from, result)
        {:noreply, %{state | current_request: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # Handle task failure
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.current_request do
      {from, _node_id, _job_id, ^ref} ->
        GenServer.reply(from, {:error, "Generation task failed: #{inspect(reason)}"})
        {:noreply, %{state | current_request: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:check_server_ready, state) do
    # Timeout detection only - primary readiness is via "listening on" in port output
    # The /v1/models endpoint returns data BEFORE the model is fully loaded,
    # so we cannot use HTTP health checks for readiness detection
    cond do
      # Already ready via port detection - nothing to do
      state.server_ready ->
        {:noreply, state}

      # Not starting - server might have crashed, stop checking
      not state.starting ->
        {:noreply, state}

      # Server starting - check for timeout
      true ->
        elapsed = System.monotonic_time(:millisecond) - (state.start_time || 0)

        cond do
          # Timeout - server probably crashed or stalled
          elapsed > 120_000 ->
            Logger.error("[sd-server] Server startup timed out after #{div(elapsed, 1000)}s")

            # Fail all pending requests
            Enum.each(state.pending_requests, fn {from, _prompt, _opts} ->
              GenServer.reply(from, {:error, "Server startup timed out"})
            end)

            {:noreply, %{state | starting: false, pending_requests: []}}

          # Still waiting - log warning if taking long
          elapsed > 30_000 ->
            Logger.warning(
              "[sd-server] Server startup taking longer than expected (#{div(elapsed, 1000)}s)"
            )

            Process.send_after(self(), :check_server_ready, 5_000)
            {:noreply, state}

          # Normal startup - keep checking
          true ->
            Process.send_after(self(), :check_server_ready, 2_000)
            {:noreply, state}
        end
    end
  end

  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    # Parse output and check for server ready signal
    lines = String.split(data, ~r/[\r\n]+/)

    # Check if server just became ready (look for "listening on" message)
    server_just_ready =
      not state.server_ready and
        Enum.any?(lines, fn line ->
          String.contains?(line, "listening on")
        end)

    # Log and broadcast progress for each line
    Enum.each(lines, fn line ->
      line = String.trim(line)

      if line != "" do
        Logger.debug("[sd-server] #{line}")
        maybe_broadcast_progress(line, state)
      end
    end)

    # If server just became ready, process pending requests
    if server_just_ready do
      Logger.info("[sd-server] Server is ready! (detected 'listening on' message)")
      new_state = %{state | server_ready: true, starting: false}

      # Process all pending requests
      Enum.each(Enum.reverse(state.pending_requests), fn {from, prompt, opts} ->
        send(self(), {:process_request, from, prompt, opts})
      end)

      {:noreply, %{new_state | pending_requests: []}}
    else
      {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.warning("[sd-server:#{state.server_port}] Server exited with code #{code}")

    # Reply to any pending requests with error
    Enum.each(state.pending_requests, fn {from, _prompt, _opts} ->
      GenServer.reply(from, {:error, "Server crashed (exit code: #{code})"})
    end)

    # Also reply to current request if any
    case state.current_request do
      {from, _node_id, _job_id, task_ref} ->
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, {:error, "Server crashed (exit code: #{code})"})

      _ ->
        :ok
    end

    # Reset to clean state
    {:noreply, fresh_state(state.server_port)}
  end

  def handle_info(msg, state) do
    Logger.debug("[sd-server] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp maybe_broadcast_progress(line, state) do
    case state.current_request do
      {_from, node_id, job_id, _ref} when not is_nil(node_id) ->
        parse_and_broadcast_progress(line, node_id, job_id)

      _ ->
        :ok
    end
  end

  defp parse_and_broadcast_progress(line, node_id, job_id) do
    case GenerationHelpers.parse_progress(line, @progress_regex) do
      {current_step, total_steps} ->
        GenerationHelpers.broadcast_progress(job_id, node_id, current_step, total_steps)

      nil ->
        :ok
    end
  end

  defp find_available_backend(requested) do
    # Try requested backend first, then common fallbacks
    backends = [requested, "cuda", "metal", "cpu"] |> Enum.uniq()

    Enum.find(backends, fn backend ->
      if server_binary_exists?(backend) do
        if backend != requested do
          Logger.info(
            "[sd-server] Requested backend '#{requested}' not available, using '#{backend}'"
          )
        end

        true
      else
        false
      end
    end)
  end

  defp server_binary_exists?(compute_backend) do
    path = server_executable_path(compute_backend)
    File.exists?(path)
  end

  defp server_executable_path(compute_backend) do
    LeaxerCore.BinaryFinder.arch_bin_path("sd-server", compute_backend)
  end

  defp detect_compute_backend do
    LeaxerCore.ComputeBackend.get_backend()
  end

  defp start_server_process(model, compute_backend, server_port, startup_params) do
    exe_path = server_executable_path(compute_backend)

    # If server binary doesn't exist, return state indicating not available
    if not File.exists?(exe_path) do
      Logger.warning("[sd-server:#{server_port}] Server binary not found at #{exe_path}")
      %__MODULE__{server_ready: false, starting: false, server_port: server_port}
    else
      # Kill any zombie process on the port first
      kill_process_on_port(server_port)

      # Read config for fallback flags (used when not in startup_params)
      config = Application.get_env(:leaxer_core, __MODULE__, [])

      # Get the LoRA model directory from user's models path
      lora_dir = Path.join(LeaxerCore.Paths.models_dir(), "lora")

      base_args = [
        "--model",
        model,
        "--listen-port",
        to_string(server_port),
        "--listen-ip",
        "127.0.0.1",
        # LoRA directory for <lora:name:weight> syntax in prompts
        "--lora-model-dir",
        lora_dir,
        # Verbose output for debugging
        "-v"
      ]

      # Build args from startup_params (with fallback to config)
      # VAE path
      vae_args =
        case Map.get(startup_params, :vae) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using VAE: #{path}")
              ["--vae", path]
            else
              Logger.warning("[sd-server:#{server_port}] VAE not found: #{path}")
              []
            end

          _ ->
            []
        end

      # VAE on CPU (from startup_params or config)
      vae_cpu_args =
        if Map.get(startup_params, :vae_on_cpu, config[:vae_on_cpu]) do
          Logger.info("[sd-server:#{server_port}] Running VAE on CPU to save VRAM")
          ["--vae-on-cpu"]
        else
          []
        end

      # VAE tiling (from startup_params or config)
      vae_tiling_args =
        if Map.get(startup_params, :vae_tiling, config[:vae_tiling]) do
          Logger.info("[sd-server:#{server_port}] VAE tiling enabled for large image support")
          ["--vae-tiling"]
        else
          []
        end

      # ControlNet model
      control_net_args =
        case Map.get(startup_params, :control_net) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using ControlNet: #{path}")
              ["--control-net", path]
            else
              Logger.warning("[sd-server:#{server_port}] ControlNet not found: #{path}")
              []
            end

          _ ->
            []
        end

      # ControlNet on CPU
      control_net_cpu_args =
        if Map.get(startup_params, :control_net_cpu) do
          Logger.info("[sd-server:#{server_port}] Running ControlNet on CPU")
          ["--control-net-cpu"]
        else
          []
        end

      # Note: control_image is passed per-request in extra_args, not at startup

      # CLIP-L text encoder
      clip_l_args =
        case Map.get(startup_params, :clip_l) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using CLIP-L: #{path}")
              ["--clip-l", path]
            else
              Logger.warning("[sd-server:#{server_port}] CLIP-L not found: #{path}")
              []
            end

          _ ->
            []
        end

      # CLIP-G text encoder
      clip_g_args =
        case Map.get(startup_params, :clip_g) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using CLIP-G: #{path}")
              ["--clip-g", path]
            else
              Logger.warning("[sd-server:#{server_port}] CLIP-G not found: #{path}")
              []
            end

          _ ->
            []
        end

      # T5-XXL text encoder
      t5xxl_args =
        case Map.get(startup_params, :t5xxl) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using T5-XXL: #{path}")
              ["--t5xxl", path]
            else
              Logger.warning("[sd-server:#{server_port}] T5-XXL not found: #{path}")
              []
            end

          _ ->
            []
        end

      # CLIP on CPU
      clip_on_cpu_args =
        if Map.get(startup_params, :clip_on_cpu) do
          Logger.info("[sd-server:#{server_port}] Running CLIP on CPU")
          ["--clip-on-cpu"]
        else
          []
        end

      # PhotoMaker (stacked ID embeddings)
      photo_maker_args =
        case Map.get(startup_params, :photo_maker) do
          path when is_binary(path) and path != "" ->
            if File.dir?(path) do
              Logger.info("[sd-server:#{server_port}] Using PhotoMaker: #{path}")
              ["--stacked-id-embed-dir", path]
            else
              Logger.warning("[sd-server:#{server_port}] PhotoMaker dir not found: #{path}")
              []
            end

          _ ->
            []
        end

      # TAESD (from startup_params, then config)
      taesd_args =
        case Map.get(startup_params, :taesd) do
          path when is_binary(path) and path != "" ->
            if File.exists?(path) do
              Logger.info("[sd-server:#{server_port}] Using TAESD decoder: #{path}")
              ["--taesd", path]
            else
              Logger.warning("[sd-server:#{server_port}] TAESD not found: #{path}")
              []
            end

          _ ->
            # Fall back to config
            if config[:taesd_enabled] do
              taesd_path = config[:taesd_path] |> Path.expand()

              if File.exists?(taesd_path) do
                Logger.info("[sd-server:#{server_port}] Using TAESD decoder: #{taesd_path}")
                ["--taesd", taesd_path]
              else
                Logger.warning(
                  "[sd-server:#{server_port}] TAESD enabled but not found: #{taesd_path}"
                )

                []
              end
            else
              []
            end
        end

      args =
        base_args ++
          vae_args ++
          vae_cpu_args ++
          vae_tiling_args ++
          control_net_args ++
          control_net_cpu_args ++
          clip_l_args ++
          clip_g_args ++
          t5xxl_args ++
          clip_on_cpu_args ++
          photo_maker_args ++
          taesd_args

      Logger.info("[sd-server:#{server_port}] Starting: #{exe_path} #{Enum.join(args, " ")}")

      # Use NativeLauncher for proper DLL/library loading on all platforms
      bin_dir = LeaxerCore.BinaryFinder.priv_bin_dir()

      {port, os_pid} =
        case LeaxerCore.NativeLauncher.spawn_executable(exe_path, args,
               bin_dir: bin_dir,
               cd: bin_dir
             ) do
          {:ok, port, os_pid} ->
            {port, os_pid}

          {:error, reason} ->
            Logger.error("[sd-server:#{server_port}] Failed to spawn: #{inspect(reason)}")
            {nil, nil}
        end

      if port == nil do
        %__MODULE__{server_ready: false, starting: false, server_port: server_port}
      else
        # Register with ProcessTracker for orphan cleanup on crash
        # Include port for fast port-based lookups (no shell scraping needed)
        if os_pid,
          do: LeaxerCore.Workers.ProcessTracker.register(os_pid, "sd-server", port: server_port)

        # Start health check timer
        Process.send_after(self(), :check_server_ready, 2_000)

        %__MODULE__{
          port: port,
          os_pid: os_pid,
          current_model: model,
          compute_backend: compute_backend,
          server_ready: false,
          server_port: server_port,
          starting: true,
          pending_requests: [],
          start_time: System.monotonic_time(:millisecond),
          startup_params: startup_params
        }
      end
    end
  end

  defp stop_server_process(state) do
    if state.os_pid do
      Logger.info("[sd-server] Killing server process #{state.os_pid}")
      # Unregister from ProcessTracker before killing
      LeaxerCore.Workers.ProcessTracker.unregister(state.os_pid)
      LeaxerCore.Platform.kill_process!(state.os_pid)
    end

    if state.port do
      try do
        Port.close(state.port)
      catch
        :error, _ -> :ok
      end
    end
  end

  defp kill_process_on_port(port) do
    # Use ProcessTracker's fast ETS-based lookup (no netstat/lsof shell scraping)
    LeaxerCore.Workers.ProcessTracker.kill_by_port(port)
    :ok
  end

  defp verify_http_connectivity(server_port) do
    # Quick connectivity check to /v1/models endpoint
    url = "http://127.0.0.1:#{server_port}/v1/models"

    Logger.debug("[sd-server:#{server_port}] Verifying HTTP connectivity to #{url}")

    case Req.get(url, receive_timeout: 15_000, connect_options: [timeout: 10_000]) do
      {:ok, %{status: 200, body: body}} ->
        body_preview = if is_binary(body), do: String.slice(body, 0, 200), else: inspect(body)
        Logger.info("[sd-server:#{server_port}] HTTP connectivity OK, response: #{body_preview}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[sd-server:#{server_port}] HTTP connectivity: unexpected status #{status}"
        )

        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("[sd-server:#{server_port}] HTTP connectivity failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[sd-server:#{server_port}] HTTP connectivity exception: #{inspect(e)}")
      {:error, e}
  end

  defp send_generation_request(prompt, opts, server_port) do
    # Check generation mode
    mode = Keyword.get(opts, :mode)
    init_img = Keyword.get(opts, :init_img)
    mask = Keyword.get(opts, :mask)

    cond do
      # Video generation mode - sd-server doesn't support this, fall back to CLI
      mode == "vid_gen" ->
        Logger.info("[sd-server:#{server_port}] Video mode requested, falling back to CLI")
        LeaxerCore.Workers.StableDiffusion.generate(prompt, opts)

      # img2img mode (has init_img)
      init_img != nil ->
        send_img2img_request(prompt, opts, init_img, mask, server_port)

      # txt2img mode (default)
      true ->
        send_txt2img_request(prompt, opts, server_port)
    end
  end

  defp send_txt2img_request(prompt, opts, server_port) do
    # Use A1111/Forge-compatible endpoint which supports direct body parameters
    # The OpenAI /v1/images/generations endpoint does NOT parse <sd_cpp_extra_args>
    url = "http://127.0.0.1:#{server_port}/sdapi/v1/txt2img"

    # Extract parameters
    negative_prompt = Keyword.get(opts, :negative_prompt, "")
    steps = Keyword.get(opts, :steps, 20)
    cfg_scale = Keyword.get(opts, :cfg_scale, 7.0)
    width = Keyword.get(opts, :width, 512) |> to_integer()
    height = Keyword.get(opts, :height, 512) |> to_integer()
    seed = Keyword.get(opts, :seed, -1)
    sampler = Keyword.get(opts, :sampler, "euler_a")

    # Generate random seed if -1, otherwise use provided seed
    actual_seed =
      if seed == -1 do
        :rand.uniform(2_147_483_647)
      else
        seed
      end

    Logger.info(
      "[sd-server] txt2img: steps=#{steps}, cfg=#{cfg_scale}, seed=#{actual_seed}#{if seed == -1, do: " (random)", else: ""}"
    )

    # Build request body (A1111/Forge format - same structure as img2img)
    body =
      %{
        "prompt" => prompt,
        "negative_prompt" => negative_prompt,
        "width" => width,
        "height" => height,
        "steps" => steps,
        "cfg_scale" => cfg_scale,
        "seed" => actual_seed,
        "sampler_name" => sampler,
        "batch_size" => 1
      }
      # Add scheduler if provided (e.g., "discrete", "karras", "ays", etc.)
      |> maybe_add("scheduler", Keyword.get(opts, :scheduler))
      # Add eta if provided (for ancestral samplers)
      |> maybe_add("eta", Keyword.get(opts, :eta))
      # Add guidance if provided (for distilled models like FLUX)
      |> maybe_add("guidance", Keyword.get(opts, :guidance))
      # Add control_strength if provided (for ControlNet)
      |> maybe_add("control_strength", Keyword.get(opts, :control_strength))
      # Add control_image path if provided (for ControlNet per-request)
      |> maybe_add("control_image", Keyword.get(opts, :control_image))
      # Add weight_type for GGUF quantization
      |> maybe_add("weight_type", Keyword.get(opts, :weight_type))
      # Chroma settings
      |> maybe_add("chroma_disable_dit_mask", Keyword.get(opts, :chroma_disable_dit_mask))
      |> maybe_add("chroma_enable_t5_mask", Keyword.get(opts, :chroma_enable_t5_mask))
      |> maybe_add("chroma_t5_mask_pad", Keyword.get(opts, :chroma_t5_mask_pad))
      # Cache settings
      |> maybe_add("cache_mode", Keyword.get(opts, :cache_mode))
      |> maybe_add("cache_preset", Keyword.get(opts, :cache_preset))
      |> maybe_add("cache_threshold", Keyword.get(opts, :cache_threshold))
      |> maybe_add("cache_warmup", Keyword.get(opts, :cache_warmup))
      |> maybe_add("cache_start_step", Keyword.get(opts, :cache_start_step))
      |> maybe_add("cache_end_step", Keyword.get(opts, :cache_end_step))
      # Reference images
      |> maybe_add("ref_image", Keyword.get(opts, :ref_image))
      |> maybe_add("additional_ref_image", Keyword.get(opts, :additional_ref_image))
      # PhotoMaker style strength
      |> maybe_add("style_strength", Keyword.get(opts, :pm_style_strength))
      # Preview settings
      |> maybe_add("preview", Keyword.get(opts, :preview))
      |> maybe_add("preview_interval", Keyword.get(opts, :preview_interval))

    Logger.info("[sd-server] Sending txt2img request to #{url}")
    Logger.debug("[sd-server] Request body: #{inspect(body)}")

    case Req.post(url,
           json: body,
           receive_timeout: @request_timeout,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        # A1111 format returns {"images": [...]} not {"data": [...]}
        # Req automatically decodes JSON, so response_body is already a map
        parse_a1111_response(response_body, opts)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[sd-server] Server returned status #{status}: #{inspect(resp_body)}")
        {:error, "Server returned status #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        Logger.error("[sd-server] HTTP request failed: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[sd-server] Request exception: #{inspect(e)}")
      {:error, "Request failed: #{inspect(e)}"}
  end

  defp send_img2img_request(prompt, opts, init_img, mask, server_port) do
    # Use AUTOMATIC1111/Forge-compatible endpoint which supports denoising_strength
    url = "http://127.0.0.1:#{server_port}/sdapi/v1/img2img"

    # Extract parameters
    negative_prompt = Keyword.get(opts, :negative_prompt, "")
    steps = Keyword.get(opts, :steps, 20)
    cfg_scale = Keyword.get(opts, :cfg_scale, 7.0)
    width = Keyword.get(opts, :width, 512) |> to_integer()
    height = Keyword.get(opts, :height, 512) |> to_integer()
    seed = Keyword.get(opts, :seed, -1)
    strength = Keyword.get(opts, :strength, 0.75)
    sampler = Keyword.get(opts, :sampler, "euler_a")

    Logger.info(
      "[sd-server] img2img: init_img=#{init_img}, mask=#{mask || "none"}, denoising_strength=#{strength}"
    )

    # Read and base64 encode the init image
    init_img_data = File.read!(init_img)
    init_img_base64 = Base.encode64(init_img_data)

    # Build request body (AUTOMATIC1111/Forge format)
    body =
      %{
        "prompt" => prompt,
        "negative_prompt" => negative_prompt,
        "init_images" => [init_img_base64],
        "denoising_strength" => strength,
        "width" => width,
        "height" => height,
        "steps" => steps,
        "cfg_scale" => cfg_scale,
        "seed" => seed,
        "sampler_name" => sampler,
        "batch_size" => 1
      }
      # Add scheduler if provided (e.g., "discrete", "karras", "ays", etc.)
      |> maybe_add("scheduler", Keyword.get(opts, :scheduler))
      # Add eta if provided (for ancestral samplers)
      |> maybe_add("eta", Keyword.get(opts, :eta))
      # Add guidance if provided (for distilled models like FLUX)
      |> maybe_add("guidance", Keyword.get(opts, :guidance))
      # Add control_strength if provided (for ControlNet)
      |> maybe_add("control_strength", Keyword.get(opts, :control_strength))
      # Add control_image path if provided (for ControlNet per-request)
      |> maybe_add("control_image", Keyword.get(opts, :control_image))
      # Add weight_type for GGUF quantization
      |> maybe_add("weight_type", Keyword.get(opts, :weight_type))
      # Chroma settings
      |> maybe_add("chroma_disable_dit_mask", Keyword.get(opts, :chroma_disable_dit_mask))
      |> maybe_add("chroma_enable_t5_mask", Keyword.get(opts, :chroma_enable_t5_mask))
      |> maybe_add("chroma_t5_mask_pad", Keyword.get(opts, :chroma_t5_mask_pad))
      # Cache settings
      |> maybe_add("cache_mode", Keyword.get(opts, :cache_mode))
      |> maybe_add("cache_preset", Keyword.get(opts, :cache_preset))
      |> maybe_add("cache_threshold", Keyword.get(opts, :cache_threshold))
      |> maybe_add("cache_warmup", Keyword.get(opts, :cache_warmup))
      |> maybe_add("cache_start_step", Keyword.get(opts, :cache_start_step))
      |> maybe_add("cache_end_step", Keyword.get(opts, :cache_end_step))
      # Reference images
      |> maybe_add("ref_image", Keyword.get(opts, :ref_image))
      |> maybe_add("additional_ref_image", Keyword.get(opts, :additional_ref_image))
      # PhotoMaker style strength
      |> maybe_add("style_strength", Keyword.get(opts, :pm_style_strength))
      # Preview settings
      |> maybe_add("preview", Keyword.get(opts, :preview))
      |> maybe_add("preview_interval", Keyword.get(opts, :preview_interval))

    # Add mask if provided (base64 encoded)
    # Also set inpainting parameters to preserve original content
    body =
      if mask && File.exists?(mask) do
        mask_data = File.read!(mask)
        mask_base64 = Base.encode64(mask_data)

        body
        |> Map.put("mask", mask_base64)
        # inpainting_fill: 1 = "original" - use original image as base for inpainting
        # This prevents random feature generation (like cat eyes) in masked areas
        |> Map.put("inpainting_fill", 1)
        # Resize mask to image size
        |> Map.put("resize_mode", 1)
        # Mask blur for smoother edges
        |> Map.put("mask_blur", 4)
      else
        body
      end

    Logger.info("[sd-server] Sending img2img request to #{url}")

    Logger.info(
      "[sd-server] img2img params: #{width}x#{height}, denoising_strength=#{strength}, steps=#{steps}"
    )

    case Req.post(url,
           json: body,
           receive_timeout: @request_timeout,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        # Req automatically decodes JSON, so response_body is already a map
        parse_a1111_response(response_body, opts)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[sd-server] img2img returned status #{status}: #{inspect(resp_body)}")
        {:error, "Server returned status #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        Logger.error("[sd-server] img2img request failed: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[sd-server] img2img exception: #{inspect(e)}")
      {:error, "Request failed: #{inspect(e)}"}
  end

  # Parse AUTOMATIC1111/Forge style response
  # Req automatically decodes JSON, so response_body is already a map
  defp parse_a1111_response(%{"images" => [base64_image | _]}, opts) do
    # Check if we should stream base64 data directly (skip disk I/O for previews)
    if Keyword.get(opts, :stream_base64, false) do
      Logger.info("[sd-server] Returning base64 data (preview mode)")
      {:ok, %{data: base64_image, mime_type: "image/png"}}
    else
      # Save the image to a file
      output_path = generate_output_path(opts)
      image_data = Base.decode64!(base64_image)
      File.write!(output_path, image_data)

      Logger.info("[sd-server] Saved to #{output_path}")
      {:ok, %{path: output_path}}
    end
  end

  defp parse_a1111_response(%{"error" => error}, _opts) do
    Logger.error("[sd-server] Error response: #{error}")
    {:error, error}
  end

  defp parse_a1111_response(other, _opts) do
    Logger.error("[sd-server] Unexpected response: #{inspect(other)}")
    {:error, "Unexpected response format"}
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_binary(val), do: String.to_integer(val)
  defp to_integer(val) when is_float(val), do: round(val)

  # Helper to conditionally add a key-value pair to a map if the value is not nil
  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp generate_output_path(opts) do
    GenerationHelpers.generate_output_path(opts)
  end
end
