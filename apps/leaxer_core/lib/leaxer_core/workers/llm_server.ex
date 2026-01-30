defmodule LeaxerCore.Workers.LLMServer do
  @moduledoc """
  GenServer that manages a persistent llama-server process for chat inference.

  Unlike the CLI-based LLM worker, this keeps the model loaded in memory
  for fast consecutive chat responses (model warming).

  ## Architecture

  This is a singleton GenServer registered as `__MODULE__`. It manages a single
  llama-server process on a configurable port (default: 8080).

  ## Supervision

  - **Restart**: Permanent (always restarted)
  - **Strategy**: Part of main supervision tree with `:one_for_one`
  - **Persistent server**: Model stays loaded between chat requests

  ## Failure Modes

  - **Server process crash**: Port receives `{:exit_status, code}`, pending
    requests fail with error, state resets. Next request restarts server.
  - **GenServer crash**: llama-server OS process becomes orphaned.
    ProcessTracker detects and kills orphan. Supervisor restarts GenServer.
  - **HTTP timeout**: Generation request fails, server may still be running.
    Next request verifies HTTP connectivity before proceeding.

  ## State Recovery

  On restart:
  - ProcessTracker kills orphaned llama-server process
  - Model must be reloaded on first chat request
  - Pending requests from before crash are lost

  ## Requirements

  The llama-server binary must be present in `priv/bin/` with platform-specific names:
  - `llama-server-aarch64-apple-darwin` (macOS ARM)
  - `llama-server-x86_64-apple-darwin` (macOS Intel)
  - `llama-server-x86_64-unknown-linux-gnu` (Linux)
  - `llama-server-x86_64-pc-windows-msvc.exe` (Windows)
  """

  use GenServer
  require Logger

  # Configuration
  @default_server_port 8080
  @default_context_size 8192

  defstruct [
    :port,
    :os_pid,
    :current_model,
    :server_ready,
    :server_port,
    :start_time,
    pending_requests: [],
    starting: false
  ]

  # Client API

  @doc """
  Start the singleton LLMServer.

  ## Options

  - `:server_port` - The port to use (default: 8080)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensure the specified model is loaded and ready for chat.

  If a different model is currently loaded, the server will restart
  with the new model. Returns when the server is ready.

  ## Options

  - `:context_size` - Context window size (default: 8192)
  """
  def ensure_model_loaded(model_path, opts \\ []) do
    GenServer.call(__MODULE__, {:ensure_model_loaded, model_path, opts}, 120_000)
  catch
    :exit, {:noproc, _} ->
      {:error, "LLMServer not running"}
  end

  @doc """
  Get the HTTP endpoint URL for chat requests.

  Returns `nil` if the server is not ready.
  """
  def get_endpoint do
    GenServer.call(__MODULE__, :get_endpoint)
  catch
    :exit, {:noproc, _} -> nil
  end

  @doc """
  Get the current server status.

  Returns `:idle`, `:loading`, `:ready`, or `{:error, reason}`.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, {:noproc, _} -> :idle
  end

  @doc """
  Get the currently loaded model path.
  """
  def current_model do
    GenServer.call(__MODULE__, :current_model)
  catch
    :exit, {:noproc, _} -> nil
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
  Check if server binary is available.
  """
  def available? do
    path = server_executable_path()
    file_or_executable_exists?(path)
  end

  # Check if path exists (for bundled binaries) or is an executable in PATH
  defp file_or_executable_exists?(path) do
    cond do
      File.exists?(path) -> true
      # If it looks like a path (has separators), don't check system PATH
      String.contains?(path, "/") or String.contains?(path, "\\") -> false
      System.find_executable(path) != nil -> true
      true -> false
    end
  end

  @doc """
  Unload the current model and stop the server to free memory.
  """
  def unload do
    GenServer.cast(__MODULE__, :unload)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Restart the LLM server. Stops any running server and resets state.
  The server will start fresh on the next model load request.
  """
  def restart do
    GenServer.call(__MODULE__, :restart, 30_000)
  catch
    :exit, {:noproc, _} -> {:error, "LLMServer not running"}
  end

  @doc """
  Get detailed health information about the LLM server.

  Returns a map with:
  - `:status` - :idle, :loading, :ready, or :stopped
  - `:model` - currently loaded model path (if any)
  - `:server_port` - the port the server listens on
  - `:os_pid` - the OS process ID (if running)
  - `:binary_available` - whether the llama-server binary exists
  """
  def get_health do
    GenServer.call(__MODULE__, :get_health)
  catch
    :exit, {:noproc, _} ->
      %{
        status: :stopped,
        model: nil,
        server_port: @default_server_port,
        os_pid: nil,
        binary_available: available?()
      }
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    server_port = Keyword.get(opts, :server_port, @default_server_port)
    Logger.info("[llama-server:#{server_port}] Instance initialized")

    state = %__MODULE__{
      server_ready: false,
      starting: false,
      server_port: server_port
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_model_loaded, model_path, opts}, from, state) do
    server_port = state.server_port

    cond do
      # Server ready with same model - just verify it's alive
      state.server_ready and state.current_model == model_path ->
        case verify_http_connectivity(server_port) do
          :ok ->
            Logger.info("[llama-server:#{server_port}] Model already loaded and ready")
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.warning(
              "[llama-server:#{server_port}] Server not responding (#{inspect(reason)}), restarting..."
            )

            if state.port, do: stop_server_process(state)
            new_state = start_server_process(model_path, server_port, opts)
            pending = [{from, model_path, opts} | new_state.pending_requests]
            {:noreply, %{new_state | pending_requests: pending}}
        end

      # Server starting - queue the request
      state.starting ->
        Logger.info("[llama-server:#{server_port}] Server starting, queuing request")
        pending = [{from, model_path, opts} | state.pending_requests]
        {:noreply, %{state | pending_requests: pending}}

      # Need to start/restart server with new model
      true ->
        Logger.info(
          "[llama-server:#{server_port}] Starting server with model: #{Path.basename(model_path)}"
        )

        # Stop existing server if running
        if state.port, do: stop_server_process(state)

        new_state = start_server_process(model_path, server_port, opts)

        # If starting failed (binary not found), reply with error immediately
        if not new_state.starting do
          {:reply, {:error, "Failed to start llama-server - binary not found"}, new_state}
        else
          pending = [{from, model_path, opts} | new_state.pending_requests]
          {:noreply, %{new_state | pending_requests: pending}}
        end
    end
  end

  def handle_call(:get_endpoint, _from, state) do
    if state.server_ready do
      {:reply, "http://127.0.0.1:#{state.server_port}", state}
    else
      {:reply, nil, state}
    end
  end

  def handle_call(:status, _from, state) do
    status =
      cond do
        state.server_ready -> :ready
        state.starting -> :loading
        true -> :idle
      end

    {:reply, status, state}
  end

  def handle_call(:current_model, _from, state) do
    {:reply, state.current_model, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.server_ready, state}
  end

  def handle_call(:restart, _from, state) do
    server_port = state.server_port
    Logger.info("[llama-server:#{server_port}] Restart requested")

    # Stop existing server if running
    if state.port do
      Logger.info("[llama-server:#{server_port}] Stopping server for restart...")
      stop_server_process(state)
    end

    # Also kill any zombie processes on the port
    kill_process_on_port(server_port)

    # Reset to fresh state
    new_state = fresh_state(server_port)
    Logger.info("[llama-server:#{server_port}] Server stopped, ready for fresh start")

    {:reply, :ok, new_state}
  end

  def handle_call(:get_health, _from, state) do
    status =
      cond do
        state.server_ready -> :ready
        state.starting -> :loading
        true -> :idle
      end

    health = %{
      status: status,
      model: state.current_model,
      server_port: state.server_port,
      os_pid: state.os_pid,
      binary_available: File.exists?(server_executable_path())
    }

    {:reply, health, state}
  end

  @impl true
  def handle_cast(:unload, state) do
    if state.port do
      Logger.info("[llama-server:#{state.server_port}] Unloading model to free memory")
      stop_server_process(state)
    end

    {:noreply, fresh_state(state.server_port)}
  end

  @impl true
  def handle_info(:check_server_ready, state) do
    cond do
      # Already ready via port detection - nothing to do
      state.server_ready ->
        {:noreply, state}

      # Not starting - server might have crashed, stop checking
      not state.starting ->
        {:noreply, state}

      # Server starting - check HTTP endpoint as fallback detection
      true ->
        elapsed = System.monotonic_time(:millisecond) - (state.start_time || 0)

        # Try HTTP health check as fallback ready detection (stdout detection may fail with batch wrapper)
        case verify_http_connectivity(state.server_port) do
          :ok ->
            Logger.info("[llama-server] Server is ready! (detected via HTTP health check)")
            new_state = %{state | server_ready: true, starting: false}

            # Broadcast status change
            Phoenix.PubSub.broadcast(
              LeaxerCore.PubSub,
              "llm_server:status",
              {:llm_server_status, :ready}
            )

            # Reply to all pending requests
            Enum.each(Enum.reverse(state.pending_requests), fn {from, _model, _opts} ->
              GenServer.reply(from, :ok)
            end)

            {:noreply, %{new_state | pending_requests: []}}

          {:error, _reason} ->
            # HTTP not ready yet, check for timeout
            cond do
              elapsed > 120_000 ->
                Logger.error(
                  "[llama-server] Server startup timed out after #{div(elapsed, 1000)}s"
                )

                Enum.each(state.pending_requests, fn {from, _model, _opts} ->
                  GenServer.reply(from, {:error, "Server startup timed out"})
                end)

                {:noreply, %{state | starting: false, pending_requests: []}}

              elapsed > 30_000 ->
                Logger.warning(
                  "[llama-server] Server startup taking longer than expected (#{div(elapsed, 1000)}s)"
                )

                Process.send_after(self(), :check_server_ready, 5_000)
                {:noreply, state}

              true ->
                Process.send_after(self(), :check_server_ready, 2_000)
                {:noreply, state}
            end
        end
    end
  end

  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    lines = String.split(data, ~r/[\r\n]+/)

    # Check if server just became ready (look for ready indicators in output)
    # llama-server outputs: "server is listening on http://127.0.0.1:8080"
    server_just_ready =
      not state.server_ready and
        Enum.any?(lines, fn line ->
          String.contains?(line, "listening on") or
            String.contains?(line, "server listening") or
            String.contains?(line, "main: server is listening")
        end)

    # Log each line for debugging and broadcast to subscribers
    Enum.each(lines, fn line ->
      line = String.trim(line)

      if line != "" do
        Logger.debug("[llama-server] #{line}")
        # Broadcast log line to subscribers for real-time streaming
        Phoenix.PubSub.broadcast(LeaxerCore.PubSub, "llm_server:logs", {:llm_server_log, line})
      end
    end)

    # If server just became ready, process pending requests
    if server_just_ready do
      Logger.info("[llama-server] Server is ready! (detected startup message)")
      new_state = %{state | server_ready: true, starting: false}

      # Broadcast status change
      Phoenix.PubSub.broadcast(
        LeaxerCore.PubSub,
        "llm_server:status",
        {:llm_server_status, :ready}
      )

      # Reply to all pending requests
      Enum.each(Enum.reverse(state.pending_requests), fn {from, _model, _opts} ->
        GenServer.reply(from, :ok)
      end)

      {:noreply, %{new_state | pending_requests: []}}
    else
      {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.warning("[llama-server:#{state.server_port}] Server exited with code #{code}")

    # Broadcast error status and log
    Phoenix.PubSub.broadcast(
      LeaxerCore.PubSub,
      "llm_server:status",
      {:llm_server_status, :error, "Server crashed (exit code: #{code})"}
    )

    Phoenix.PubSub.broadcast(
      LeaxerCore.PubSub,
      "llm_server:logs",
      {:llm_server_log, "❌ Server exited with code #{code}"}
    )

    # Reply to any pending requests with error
    Enum.each(state.pending_requests, fn {from, _model, _opts} ->
      GenServer.reply(from, {:error, "Server crashed (exit code: #{code})"})
    end)

    # Reset to clean state
    {:noreply, fresh_state(state.server_port)}
  end

  def handle_info(msg, state) do
    Logger.debug("[llama-server] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp fresh_state(server_port) do
    %__MODULE__{
      port: nil,
      os_pid: nil,
      current_model: nil,
      server_ready: false,
      server_port: server_port,
      start_time: nil,
      pending_requests: [],
      starting: false
    }
  end

  defp start_server_process(model_path, server_port, opts) do
    exe_path = server_executable_path()

    # For system binaries (no path separator), resolve full path via which
    exe_path =
      if String.contains?(exe_path, "/") or String.contains?(exe_path, "\\") do
        exe_path
      else
        System.find_executable(exe_path) || exe_path
      end

    if not file_or_executable_exists?(exe_path) do
      Logger.warning("[llama-server:#{server_port}] Server binary not found at #{exe_path}")
      %__MODULE__{server_ready: false, starting: false, server_port: server_port}
    else
      # Kill any zombie process on the port first
      kill_process_on_port(server_port)

      context_size = Keyword.get(opts, :context_size, @default_context_size)

      args = [
        "--model",
        model_path,
        "--port",
        to_string(server_port),
        "--host",
        "127.0.0.1",
        "-c",
        to_string(context_size)
      ]

      Logger.info("[llama-server:#{server_port}] Starting: #{exe_path} #{Enum.join(args, " ")}")

      # Use NativeLauncher for proper DLL/library loading on all platforms
      bin_dir = LeaxerCore.BinaryFinder.priv_bin_dir()

      # Log detailed information before spawning (helpful for debugging DLL issues)
      Logger.info("[llama-server:#{server_port}] bin_dir for NativeLauncher: #{bin_dir}")
      Logger.info("[llama-server:#{server_port}] exe_path: #{exe_path}")
      Logger.info("[llama-server:#{server_port}] exe_path exists: #{File.exists?(exe_path)}")

      # On Windows, log DLL presence explicitly
      if match?({:win32, _}, :os.type()) do
        llama_dll = Path.join(bin_dir, "llama.dll")
        Logger.info("[llama-server:#{server_port}] llama.dll path: #{llama_dll}")
        Logger.info("[llama-server:#{server_port}] llama.dll exists: #{File.exists?(llama_dll)}")
      end

      {port, os_pid} =
        case LeaxerCore.NativeLauncher.spawn_executable(exe_path, args,
               bin_dir: bin_dir,
               cd: bin_dir
             ) do
          {:ok, port, os_pid} ->
            Logger.info(
              "[llama-server:#{server_port}] Successfully spawned, OS PID: #{inspect(os_pid)}"
            )

            {port, os_pid}

          {:error, reason} ->
            Logger.error("[llama-server:#{server_port}] Failed to spawn: #{inspect(reason)}")
            {nil, nil}
        end

      if port == nil do
        %__MODULE__{server_ready: false, starting: false, server_port: server_port}
      else
        # Register with ProcessTracker for orphan cleanup on crash
        if os_pid,
          do:
            LeaxerCore.Workers.ProcessTracker.register(os_pid, "llama-server", port: server_port)

        # Start health check timer
        Process.send_after(self(), :check_server_ready, 2_000)

        # Broadcast that we're starting
        Phoenix.PubSub.broadcast(
          LeaxerCore.PubSub,
          "llm_server:status",
          {:llm_server_status, :loading, model_path}
        )

        %__MODULE__{
          port: port,
          os_pid: os_pid,
          current_model: model_path,
          server_ready: false,
          server_port: server_port,
          starting: true,
          pending_requests: [],
          start_time: System.monotonic_time(:millisecond)
        }
      end
    end
  end

  defp stop_server_process(state) do
    if state.os_pid do
      Logger.info("[llama-server] Killing server process #{state.os_pid}")
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
    LeaxerCore.Workers.ProcessTracker.kill_by_port(port)
    :ok
  end

  defp verify_http_connectivity(server_port) do
    url = "http://127.0.0.1:#{server_port}/health"

    Logger.debug("[llama-server:#{server_port}] Verifying HTTP connectivity to #{url}")

    case Req.get(url, receive_timeout: 10_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200}} ->
        Logger.debug("[llama-server:#{server_port}] HTTP connectivity OK")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[llama-server:#{server_port}] HTTP connectivity: unexpected status #{status}"
        )

        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("[llama-server:#{server_port}] HTTP connectivity failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[llama-server:#{server_port}] HTTP connectivity exception: #{inspect(e)}")
      {:error, e}
  end

  defp server_executable_path do
    # Detect best compute backend based on available hardware
    backend = detect_compute_backend()

    # Try llama-server with detected backend, falling back to CPU
    primary =
      LeaxerCore.BinaryFinder.find_arch_binary("llama-server", backend, fallback_cpu: true)

    cond do
      primary != nil and binary_works?(primary) ->
        primary

      # Try alternate naming convention
      (fallback =
         LeaxerCore.BinaryFinder.find_arch_binary("llama.cpp-server", backend, fallback_cpu: true)) !=
        nil and binary_works?(fallback) ->
        fallback

      # Try system llama-server (e.g., installed via homebrew)
      system_binary_available?("llama-server") ->
        Logger.info("[llama-server] Using system llama-server binary")
        "llama-server"

      # Fall back to system llama.cpp-server
      system_binary_available?("llama.cpp-server") ->
        Logger.info("[llama-server] Using system llama.cpp-server binary")
        "llama.cpp-server"

      # Return a path that won't exist (will trigger error handling)
      true ->
        LeaxerCore.BinaryFinder.arch_bin_path("llama-server", "cpu")
    end
  end

  # Check if a binary can actually run (not just exists)
  defp binary_works?(path) do
    case System.cmd(path, ["--help"], stderr_to_stdout: true) do
      {_, 0} -> true
      # llama-server returns 1 for --help but that's OK
      {_, 1} -> true
      {output, _} -> not String.contains?(output, "Library not loaded")
    end
  rescue
    _ -> false
  end

  # Check if a binary is available in system PATH
  defp system_binary_available?(name) do
    case System.cmd("which", [name], stderr_to_stdout: true) do
      {path, 0} when path != "" -> File.exists?(String.trim(path))
      _ -> false
    end
  rescue
    _ -> false
  end

  defp detect_compute_backend do
    LeaxerCore.ComputeBackend.get_backend()
  end
end
