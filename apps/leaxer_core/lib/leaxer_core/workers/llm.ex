defmodule LeaxerCore.Workers.LLM do
  @moduledoc """
  GenServer worker for llama.cpp.

  Handles text generation with support for streaming output, constrained generation
  via grammar, and single-job execution pattern.

  ## Supervision

  - **Restart**: Permanent (always restarted)
  - **Strategy**: Part of main supervision tree with `:one_for_one`
  - **Single-job pattern**: Only one generation runs at a time

  ## Failure Modes

  - **Port crash**: GenServer receives `{:exit_status, code}` or `{:DOWN, ...}`,
    replies with error to caller, resets state. Next request starts fresh.
  - **GenServer crash**: Current generation fails, OS process may be orphaned.
    On restart, state is clean but llama-cli process may still be running.
  - **Abort requested**: OS process killed via SIGKILL/taskkill, caller gets
    `{:error, :aborted}`.

  ## State Recovery

  Worker state is transient - no persistence. On restart:
  - New generation requests work immediately
  - Any in-flight generation is lost
  - Accumulated generated text is lost

  ## Usage

      LeaxerCore.Workers.LLM.generate("Describe this image in detail", [
        model: "/path/to/model.gguf",
        max_tokens: 512,
        temperature: 0.7
      ])

  ## Binary Location

  The llama.cpp binary should be placed in `priv/bin/` with platform-specific names:
  - `llama-aarch64-apple-darwin` (macOS ARM)
  - `llama-x86_64-apple-darwin` (macOS Intel)
  - `llama-x86_64-unknown-linux-gnu` (Linux)
  - `llama-x86_64-pc-windows-msvc.exe` (Windows)
  """

  use GenServer
  require Logger

  # Default generation timeout: 5 minutes
  @default_timeout 300_000

  defstruct [
    :port,
    :caller,
    :model,
    :start_time,
    :job_id,
    :node_id,
    :os_pid,
    buffer: "",
    generated_text: ""
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate text using llama.cpp.

  ## Options

  - `:model` - Path to the GGUF model file - REQUIRED
  - `:max_tokens` - Maximum tokens to generate (default: 512)
  - `:temperature` - Sampling temperature (default: 0.7)
  - `:top_p` - Top-p sampling (default: 0.9)
  - `:top_k` - Top-k sampling (default: 40)
  - `:grammar` - Grammar string for constrained generation (optional)
  - `:grammar_file` - Path to grammar file for constrained generation (optional)

  ## Returns

  - `{:ok, %{text: String.t()}}` on success
  - `{:error, reason}` on failure
  """
  def generate(prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(__MODULE__, {:generate, prompt, opts}, timeout)
  end

  @doc """
  Check if the worker is currently busy.
  """
  def busy? do
    GenServer.call(__MODULE__, :busy?)
  end

  @doc """
  Abort the current generation.
  """
  def abort do
    GenServer.cast(__MODULE__, :abort)
  end

  @doc """
  Get the currently loaded model path, if any.
  """
  def current_model do
    GenServer.call(__MODULE__, :current_model)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:generate, prompt, opts}, from, state) do
    # Kill existing process if any (single-threaded worker pattern)
    if state.port, do: cleanup_port(state.port)

    model = Keyword.fetch!(opts, :model)
    node_id = Keyword.get(opts, :node_id)

    unless File.exists?(model) do
      {:reply, {:error, "Model file not found: #{model}"}, state}
    else
      # Generate unique job ID
      job_id = generate_job_id()

      # Build command arguments
      args = build_args(prompt, opts)

      # Get executable path
      exe_path = executable_path()

      Logger.info("[llama.cpp] Starting generation job #{job_id}")
      Logger.debug("[llama.cpp] Command: #{exe_path} #{Enum.join(args, " ")}")

      # Use NativeLauncher for proper DLL/library loading on all platforms
      bin_dir = LeaxerCore.BinaryFinder.priv_bin_dir()

      {port, os_pid} =
        case LeaxerCore.NativeLauncher.spawn_executable(exe_path, args,
               bin_dir: bin_dir,
               cd: bin_dir,
               port_opts: [:line]
             ) do
          {:ok, port, os_pid} ->
            {port, os_pid}

          {:error, reason} ->
            Logger.error("[llama.cpp] Failed to spawn: #{inspect(reason)}")
            {nil, nil}
        end

      if port == nil do
        {:reply, {:error, "Failed to start llama.cpp process"}, state}
      else
        Logger.debug("[llama.cpp] Started process with OS PID: #{inspect(os_pid)}")

        # Register with ProcessTracker for orphan cleanup on crash
        if os_pid, do: LeaxerCore.Workers.ProcessTracker.register(os_pid, "llama-cli")

        new_state = %__MODULE__{
          port: port,
          caller: from,
          model: model,
          start_time: System.monotonic_time(:millisecond),
          job_id: job_id,
          node_id: node_id,
          os_pid: os_pid
        }

        {:noreply, new_state}
      end
    end
  end

  def handle_call(:busy?, _from, state) do
    {:reply, state.port != nil, state}
  end

  def handle_call(:current_model, _from, state) do
    {:reply, state.model, state}
  end

  @impl true
  def handle_cast(:abort, state) do
    Logger.info(
      "[llama.cpp] Abort requested, port=#{inspect(state.port)}, os_pid=#{inspect(state.os_pid)}"
    )

    if state.port do
      Logger.info("[llama.cpp] Aborting job #{state.job_id}, OS PID: #{inspect(state.os_pid)}")

      # Kill the OS process first using stored PID
      if state.os_pid do
        Logger.info("[llama.cpp] Killing OS process #{state.os_pid}")
        kill_os_process(state.os_pid)
      else
        Logger.warning("[llama.cpp] No OS PID stored, cannot kill process")
      end

      # Then close the port
      Logger.info("[llama.cpp] Closing port")
      cleanup_port(state.port)

      if state.caller do
        Logger.info("[llama.cpp] Replying to caller with :aborted")
        GenServer.reply(state.caller, {:error, :aborted})
      end
    else
      Logger.info("[llama.cpp] No port to abort")
    end

    {:noreply, reset_state(state)}
  end

  @impl true
  def handle_info({_port, {:data, {_, data}}}, state) when is_binary(data) do
    line = String.trim(data)

    # Skip empty lines and system messages
    if line != "" and not String.starts_with?(line, "llm_load_") and
         not String.starts_with?(line, "llama_model_") do
      # For llama.cpp, generated text is typically printed directly to stdout
      # We accumulate all output as generated text for streaming
      new_generated_text = state.generated_text <> line <> "\n"

      # Broadcast streaming progress if we have a node_id
      if state.node_id do
        broadcast_streaming_text(state.job_id, state.node_id, line)
      end

      {:noreply, %{state | generated_text: new_generated_text}}
    else
      Logger.debug("[llama.cpp] #{line}")
      {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, 0}}, state) do
    # Success!
    elapsed = System.monotonic_time(:millisecond) - state.start_time
    Logger.info("[llama.cpp] Job #{state.job_id} completed in #{elapsed}ms")

    # Clean up and extract the final generated text
    final_text = String.trim(state.generated_text)

    result = %{
      text: final_text,
      job_id: state.job_id,
      elapsed_ms: elapsed
    }

    if state.caller do
      GenServer.reply(state.caller, {:ok, result})
    end

    broadcast_completion(state.job_id, result)
    {:noreply, reset_state(state)}
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    # Failure - but Elixir stays alive!
    Logger.error("[llama.cpp] Job #{state.job_id} failed with exit code #{code}")

    if state.caller do
      GenServer.reply(state.caller, {:error, "Generation failed (exit code: #{code})"})
    end

    broadcast_error(state.job_id, "Generation failed (exit code: #{code})")
    {:noreply, reset_state(state)}
  end

  def handle_info({:DOWN, _ref, :port, _port, reason}, state) do
    Logger.error("[llama.cpp] Port crashed: #{inspect(reason)}")

    if state.caller do
      GenServer.reply(state.caller, {:error, "Process crashed"})
    end

    {:noreply, reset_state(state)}
  end

  # Private Functions

  defp build_args(prompt, opts) do
    model = Keyword.fetch!(opts, :model)

    base = [
      "--model",
      model,
      "-p",
      prompt,
      "-n",
      to_string(Keyword.get(opts, :max_tokens, 512)),
      "--temp",
      to_string(Keyword.get(opts, :temperature, 0.7)),
      "--top-p",
      to_string(Keyword.get(opts, :top_p, 0.9)),
      "--top-k",
      to_string(Keyword.get(opts, :top_k, 40)),
      # Enable special tokens to ensure proper output
      "--special"
    ]

    # Add grammar for constrained generation if provided
    base =
      case Keyword.get(opts, :grammar) do
        nil -> base
        grammar -> base ++ ["--grammar", grammar]
      end

    # Add grammar file if provided (takes precedence over inline grammar)
    base =
      case Keyword.get(opts, :grammar_file) do
        nil -> base
        file when is_binary(file) and file != "" -> base ++ ["--grammar-file", file]
        _ -> base
      end

    base
  end

  defp executable_path do
    alias LeaxerCore.BinaryFinder

    # Detect best compute backend based on available hardware
    backend = detect_compute_backend()

    # Try primary binary name first with detected backend
    primary = BinaryFinder.find_arch_binary("llama", backend, fallback_cpu: true)

    cond do
      primary != nil ->
        primary

      # Try fallback naming (llama-cli)
      (fallback = BinaryFinder.find_arch_binary("llama-cli", backend, fallback_cpu: true)) != nil ->
        fallback

      # Fall back to system binary
      true ->
        Logger.warning("[llama.cpp] Binary not found, using system 'llama-cli'")
        "llama-cli"
    end
  end

  defp detect_compute_backend do
    LeaxerCore.ComputeBackend.get_backend()
  end

  defp cleanup_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp kill_os_process(os_pid) do
    Logger.info("[llama.cpp] Attempting to kill OS process #{os_pid}")

    case LeaxerCore.Platform.kill_process(os_pid) do
      {:ok, output} ->
        Logger.info("[llama.cpp] Process #{os_pid} killed successfully: #{inspect(output)}")

      {:error, {output, exit_code}} ->
        Logger.warning(
          "[llama.cpp] Failed to kill process #{os_pid}: exit_code=#{exit_code}, output=#{inspect(output)}"
        )
    end

    :ok
  end

  defp reset_state(state) do
    # Unregister from ProcessTracker when resetting
    if state.os_pid do
      LeaxerCore.Workers.ProcessTracker.unregister(state.os_pid)
    end

    %__MODULE__{}
  end

  defp generate_job_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp broadcast_streaming_text(job_id, node_id, text_chunk) do
    Phoenix.PubSub.broadcast(LeaxerCore.PubSub, "llm:streaming", %{
      job_id: job_id,
      node_id: node_id,
      text_chunk: text_chunk
    })
  end

  defp broadcast_completion(job_id, result) do
    Phoenix.PubSub.broadcast(LeaxerCore.PubSub, "llm:complete", %{
      job_id: job_id,
      text: result.text,
      elapsed_ms: result.elapsed_ms
    })
  end

  defp broadcast_error(job_id, error) do
    Phoenix.PubSub.broadcast(LeaxerCore.PubSub, "llm:error", %{
      job_id: job_id,
      error: error
    })
  end
end
