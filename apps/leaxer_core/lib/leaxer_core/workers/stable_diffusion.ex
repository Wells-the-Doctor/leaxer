defmodule LeaxerCore.Workers.StableDiffusion do
  @moduledoc """
  GenServer worker for stable-diffusion.cpp.

  Handles progress parsing, crash recovery, and single-job execution.
  Uses Port with `:line` option for proper stdout buffering.

  ## Supervision

  - **Restart**: Permanent (always restarted)
  - **Strategy**: Part of main supervision tree with `:one_for_one`
  - **Single-job pattern**: Only one generation runs at a time

  ## Failure Modes

  - **Port crash**: GenServer receives `{:DOWN, ...}` or `{:exit_status, code}`,
    replies with error to caller, resets state for next job.
  - **GenServer crash**: Current generation fails, OS process may become orphaned.
    On restart, state is clean but orphaned sd.cpp process continues until done.
  - **Abort requested**: OS process killed via SIGKILL (Unix) or taskkill (Windows),
    port closed, caller receives `{:error, :aborted}`.

  ## State Recovery

  Worker state is transient - no persistence. On restart:
  - New jobs can be submitted immediately
  - Any in-flight generation is lost
  - OS process from previous generation may still be running (orphaned)

  ## Usage

      LeaxerCore.Workers.StableDiffusion.generate("a photo of a cat", [
        model: "/path/to/model.safetensors",
        steps: 20,
        cfg_scale: 7.0,
        width: 512,
        height: 512
      ])

  ## Binary Location

  The sd.cpp binary should be placed in `priv/bin/` with platform-specific names:
  - `sd-aarch64-apple-darwin` (macOS ARM)
  - `sd-x86_64-apple-darwin` (macOS Intel)
  - `sd-x86_64-unknown-linux-gnu` (Linux)
  - `sd-x86_64-pc-windows-msvc.exe` (Windows)
  """

  use GenServer
  require Logger

  alias LeaxerCore.Workers.GenerationHelpers

  # Regex to catch progress output from sd.cpp
  # Format: "|==>   | 1/20 - 9.45s/it" or "| 1/5 - 1.83it/s"
  # Matches both "s/it" and "it/s" formats
  @progress_regex ~r/\|\s*(\d+)\/(\d+)\s*-\s*[\d.]+(?:s\/it|it\/s)/

  # Default generation timeout: 10 minutes
  @default_timeout 600_000

  defstruct [
    :port,
    :caller,
    :output_path,
    :job_id,
    :model,
    :start_time,
    :compute_backend,
    :node_id,
    :os_pid,
    buffer: ""
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate an image or video using stable-diffusion.cpp.

  ## Options

  - `:model` - Path to the model file (.safetensors, .ckpt, or .gguf) - REQUIRED
  - `:negative_prompt` - Negative prompt (default: "")
  - `:steps` - Number of sampling steps (default: 20)
  - `:cfg_scale` - Classifier-free guidance scale (default: 7.0)
  - `:width` - Image width (default: 512)
  - `:height` - Image height (default: 512)
  - `:seed` - Random seed, -1 for random (default: -1)
  - `:sampler` - Sampler method (default: "euler_a")
  - `:lora` - LoRA model name (optional)
  - `:output_dir` - Output directory (default: user outputs dir)

  ### Video generation options (mode: "vid_gen" for Wan2.1/2.2):
  - `:mode` - Generation mode ("vid_gen" for video)
  - `:video_frames` - Number of frames to generate (1-33)
  - `:fps` - Frames per second (default: 24)
  - `:flow_shift` - Flow shift parameter for video models
  - `:moe_boundary` - MoE boundary parameter for Wan models
  - `:vace_strength` - VACE strength for video generation

  ### I2V/FLF2V options (image-to-video, first-last-frame video):
  - `:init_img` - Path to initial frame image (enables I2V mode)
  - `:end_img` - Path to end frame image (enables FLF2V mode, requires init_img)
  - `:clip_vision` - Path to CLIP vision model for I2V/FLF2V modes

  ## Returns

  - `{:ok, %{path: String.t(), seed: integer()}}` on success (path to .png or .mp4)
  - `{:error, reason}` on failure
  """
  def generate(prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(__MODULE__, {:generate, prompt, opts}, timeout)
  end

  @doc """
  Check if the worker is currently busy generating.
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
    compute_backend = Keyword.get(opts, :compute_backend, "auto")
    node_id = Keyword.get(opts, :node_id)

    unless File.exists?(model) do
      {:reply, {:error, "Model file not found: #{model}"}, state}
    else
      # Generate unique job ID and output path
      job_id = generate_job_id()
      output_path = generate_output_path(opts)

      # Build command arguments
      args = build_args(prompt, opts, output_path)

      # Get executable path based on compute backend
      exe_path = executable_path(compute_backend)

      Logger.info("[sd.cpp] Starting generation job #{job_id} with backend: #{compute_backend}")
      Logger.info("[sd.cpp] Command: #{exe_path} #{Enum.join(args, " ")}")

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
            Logger.error("[sd.cpp] Failed to spawn: #{inspect(reason)}")
            {nil, nil}
        end

      if port == nil do
        {:reply, {:error, "Failed to start sd.cpp process"}, state}
      else
        Logger.debug("[sd.cpp] Started process with OS PID: #{inspect(os_pid)}")

        # Register with ProcessTracker for orphan cleanup on crash
        if os_pid, do: LeaxerCore.Workers.ProcessTracker.register(os_pid, "sd.cpp")

        new_state = %__MODULE__{
          port: port,
          caller: from,
          output_path: output_path,
          job_id: job_id,
          model: model,
          start_time: System.monotonic_time(:millisecond),
          compute_backend: compute_backend,
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
      "[sd.cpp] Abort requested, port=#{inspect(state.port)}, os_pid=#{inspect(state.os_pid)}"
    )

    if state.port do
      Logger.info("[sd.cpp] Aborting job #{state.job_id}, OS PID: #{inspect(state.os_pid)}")

      # Kill the OS process first using stored PID
      if state.os_pid do
        Logger.info("[sd.cpp] Killing OS process #{state.os_pid}")
        kill_os_process(state.os_pid)
      else
        Logger.warning("[sd.cpp] No OS PID stored, cannot kill process")
      end

      # Then close the port
      Logger.info("[sd.cpp] Closing port")
      cleanup_port(state.port)

      # Clear execution state
      LeaxerCore.ExecutionState.complete_execution()

      if state.caller do
        Logger.info("[sd.cpp] Replying to caller with :aborted")
        GenServer.reply(state.caller, {:error, :aborted})
      end
    else
      Logger.info("[sd.cpp] No port to abort")
    end

    {:noreply, reset_state(state)}
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    # Accumulate data and process lines (split on \r or \n)
    buffer = state.buffer <> data

    # Split on carriage return or newline to get progress updates
    # sd.cpp uses \r for progress bar updates
    lines = String.split(buffer, ~r/[\r\n]+/)

    # Keep the last incomplete line in the buffer
    {complete_lines, [remaining]} =
      case lines do
        [] -> {[], [""]}
        _ -> Enum.split(lines, -1)
      end

    # Process each complete line
    Enum.each(complete_lines, fn line ->
      line = String.trim(line)

      if line != "" do
        parse_and_broadcast_progress(line, state.job_id, state.node_id)
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  def handle_info({_port, {:exit_status, 0}}, state) do
    # Success!
    elapsed = System.monotonic_time(:millisecond) - state.start_time
    Logger.info("[sd.cpp] Job #{state.job_id} completed in #{elapsed}ms")

    result = %{
      path: state.output_path,
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
    Logger.error("[sd.cpp] Job #{state.job_id} failed with exit code #{code}")

    if state.caller do
      GenServer.reply(state.caller, {:error, "Generation failed (exit code: #{code})"})
    end

    broadcast_error(state.job_id, "Generation failed (exit code: #{code})")
    {:noreply, reset_state(state)}
  end

  def handle_info({:DOWN, _ref, :port, _port, reason}, state) do
    Logger.error("[sd.cpp] Port crashed: #{inspect(reason)}")

    if state.caller do
      GenServer.reply(state.caller, {:error, "Process crashed"})
    end

    {:noreply, reset_state(state)}
  end

  # Private Functions

  # Argument configuration types:
  # - {:value, key, flag} - Add [flag, value] if key is present and non-empty
  # - {:value, key, flag, :to_string} - Same but convert value to string
  # - {:flag, key, flag} - Add [flag] if key is truthy
  # - {:skip_values, key, flag, skip_list} - Add [flag, value] if value not in skip_list
  # - {:custom, fun} - Call fun.(opts) to get args or []
  @arg_specs [
    # Text encoders (FLUX.1, SD3.5)
    {:value, :clip_l, "--clip_l"},
    {:value, :clip_g, "--clip_g"},
    {:value, :t5xxl, "--t5xxl"},
    {:flag, :clip_on_cpu, "--clip-on-cpu"},

    # VAE settings
    {:value, :vae, "--vae"},
    {:flag, :vae_on_cpu, "--vae-on-cpu"},

    # img2img parameters
    {:value, :init_img, "-i"},
    {:value, :mask, "--mask"},

    # LLM/diffusion model paths
    {:value, :llm, "--llm"},
    {:value, :diffusion_model, "--diffusion-model"},
    {:flag, :diffusion_fa, "--diffusion-fa"},
    {:value, :llm_vision, "--llm_vision"},
    {:value, :qwen_image_zero_cond_t, "--qwen-image-zero-cond-t", :to_string},

    # Chroma model settings
    {:flag, :chroma_disable_dit_mask, "--chroma-disable-dit-mask"},
    {:flag, :chroma_enable_t5_mask, "--chroma-enable-t5-mask"},
    {:skip_values, :chroma_t5_mask_pad, "--chroma-t5-mask-pad", [nil, 0], :to_string},

    # Preview settings
    {:skip_values, :preview, "--preview", [nil, "none"]},
    {:value, :taesd, "--taesd"},
    {:value, :preview_interval, "--preview-interval", :to_string},

    # Cache settings
    {:skip_values, :cache_mode, "--cache-mode", [nil, "none"]},
    {:value, :cache_preset, "--cache-preset"},

    # Sampler settings
    {:value, :scheduler, "--scheduler"},
    {:skip_values, :eta, "--eta", [nil, 0.0], :to_string},

    # Reference images
    {:value, :ref_image, "-r"},

    # Flags
    {:flag, :increase_ref_index, "--increase-ref-index"}
  ]

  defp build_args(prompt, opts, output_path) do
    model = Keyword.fetch!(opts, :model)

    # Base arguments that are always present
    base_args = [
      "-m",
      model,
      "-p",
      prompt,
      "--steps",
      to_string(Keyword.get(opts, :steps, 20)),
      "--cfg-scale",
      to_string(Keyword.get(opts, :cfg_scale, 7.0)),
      "-W",
      to_string(Keyword.get(opts, :width, 512)),
      "-H",
      to_string(Keyword.get(opts, :height, 512)),
      "--seed",
      to_string(Keyword.get(opts, :seed, -1)),
      "--sampling-method",
      Keyword.get(opts, :sampler, "euler_a"),
      "--mmap",
      "-o",
      output_path
    ]

    # Build args from specs
    base_args
    |> add_negative_prompt(opts)
    |> add_weight_type(opts)
    |> add_lora(opts)
    |> add_vae_tiling(opts)
    |> add_img2img_strength(opts)
    |> add_controlnet(opts)
    |> add_video_mode(opts)
    |> add_photomaker(opts)
    |> add_flow_shift_non_video(opts)
    |> add_cache_options(opts)
    |> add_additional_refs(opts)
    |> apply_arg_specs(opts, @arg_specs)
  end

  # Apply declarative argument specs
  defp apply_arg_specs(args, opts, specs) do
    Enum.reduce(specs, args, fn spec, acc ->
      apply_arg_spec(acc, opts, spec)
    end)
  end

  defp apply_arg_spec(args, opts, {:value, key, flag}) do
    case Keyword.get(opts, key) do
      nil -> args
      "" -> args
      value -> args ++ [flag, value]
    end
  end

  defp apply_arg_spec(args, opts, {:value, key, flag, :to_string}) do
    case Keyword.get(opts, key) do
      nil -> args
      "" -> args
      value -> args ++ [flag, to_string(value)]
    end
  end

  defp apply_arg_spec(args, opts, {:flag, key, flag}) do
    if Keyword.get(opts, key, false), do: args ++ [flag], else: args
  end

  defp apply_arg_spec(args, opts, {:skip_values, key, flag, skip_list}) do
    value = Keyword.get(opts, key)
    if value in skip_list, do: args, else: args ++ [flag, value]
  end

  defp apply_arg_spec(args, opts, {:skip_values, key, flag, skip_list, :to_string}) do
    value = Keyword.get(opts, key)
    if value in skip_list, do: args, else: args ++ [flag, to_string(value)]
  end

  # Specialized argument builders for complex cases

  defp add_negative_prompt(args, opts) do
    case Keyword.get(opts, :negative_prompt) do
      nil -> args
      "" -> args
      neg -> args ++ ["-n", neg]
    end
  end

  defp add_weight_type(args, opts) do
    case Keyword.get(opts, :weight_type) do
      nil -> args
      "default" -> args
      weight_type -> args ++ ["--type", weight_type]
    end
  end

  defp add_lora(args, opts) do
    case Keyword.get(opts, :lora_model_dir) do
      nil ->
        args

      lora_model_dir ->
        lora_args = ["--lora-model-dir", lora_model_dir]

        lora_args =
          case Keyword.get(opts, :lora_apply_mode) do
            nil -> lora_args
            mode -> lora_args ++ ["--lora-apply-mode", mode]
          end

        args ++ lora_args
    end
  end

  defp add_vae_tiling(args, opts) do
    if Keyword.get(opts, :vae_tiling) do
      tile_args = args ++ ["--vae-tiling"]

      case Keyword.get(opts, :vae_tile_size) do
        nil -> tile_args
        size -> tile_args ++ ["--vae-tile-size", to_string(size)]
      end
    else
      args
    end
  end

  defp add_img2img_strength(args, opts) do
    if Keyword.get(opts, :init_img) do
      strength = Keyword.get(opts, :strength, 0.75)
      args ++ ["--strength", to_string(strength)]
    else
      args
    end
  end

  defp add_controlnet(args, opts) do
    case {Keyword.get(opts, :control_net), Keyword.get(opts, :control_image)} do
      {nil, _} ->
        args

      {_, nil} ->
        args

      {control_net, control_image} ->
        cn_args = ["--control-net", control_net, "--control-image", control_image]

        cn_args =
          case Keyword.get(opts, :control_strength) do
            nil -> cn_args
            strength -> cn_args ++ ["--control-strength", to_string(strength)]
          end

        cn_args =
          if Keyword.get(opts, :control_net_cpu, false) do
            cn_args ++ ["--control-net-cpu"]
          else
            cn_args
          end

        args ++ cn_args
    end
  end

  defp add_video_mode(args, opts) do
    case Keyword.get(opts, :mode) do
      "vid_gen" ->
        video_args =
          ["-M", "vid_gen"]
          |> add_video_opt(opts, :video_frames, "--video-frames")
          |> add_video_opt(opts, :fps, "--fps")
          |> add_video_opt(opts, :flow_shift, "--flow-shift")
          |> add_video_opt(opts, :moe_boundary, "--moe-boundary")
          |> add_video_opt(opts, :vace_strength, "--vace-strength")
          |> add_video_opt_string(opts, :end_img, "--end-img")
          |> add_video_opt_string(opts, :clip_vision, "--clip_vision")

        args ++ video_args

      _ ->
        args
    end
  end

  defp add_video_opt(args, opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> args
      value -> args ++ [flag, to_string(value)]
    end
  end

  defp add_video_opt_string(args, opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> args
      "" -> args
      value -> args ++ [flag, value]
    end
  end

  defp add_photomaker(args, opts) do
    case Keyword.get(opts, :photo_maker) do
      nil ->
        args

      "" ->
        args

      photo_maker_path ->
        pm_args =
          ["--photo-maker", photo_maker_path]
          |> add_video_opt_string(opts, :pm_id_images_dir, "--pm-id-images-dir")
          |> add_video_opt(opts, :pm_style_strength, "--pm-style-strength")
          |> add_video_opt_string(opts, :pm_id_embed_path, "--pm-id-embed-path")

        args ++ pm_args
    end
  end

  defp add_flow_shift_non_video(args, opts) do
    case Keyword.get(opts, :mode) do
      # Handled in video mode
      "vid_gen" ->
        args

      _ ->
        case Keyword.get(opts, :flow_shift) do
          nil -> args
          shift -> args ++ ["--flow-shift", to_string(shift)]
        end
    end
  end

  defp add_cache_options(args, opts) do
    cache_options =
      []
      |> add_cache_opt(opts, :cache_threshold, "threshold")
      |> add_cache_opt(opts, :cache_warmup, "warmup")
      |> add_cache_opt(opts, :cache_start_step, "start_step")
      |> add_cache_opt(opts, :cache_end_step, "end_step")

    if length(cache_options) > 0 do
      args ++ ["--cache-option", Enum.join(cache_options, ",")]
    else
      args
    end
  end

  defp add_cache_opt(opts_list, opts, key, name) do
    case Keyword.get(opts, key) do
      nil -> opts_list
      value -> opts_list ++ ["#{name}=#{value}"]
    end
  end

  defp add_additional_refs(args, opts) do
    additional_refs = Keyword.get_values(opts, :additional_ref_image)

    Enum.reduce(additional_refs, args, fn ref_path, acc ->
      if is_binary(ref_path) and ref_path != "" do
        acc ++ ["-r", ref_path]
      else
        acc
      end
    end)
  end

  defp executable_path(compute_backend) do
    alias LeaxerCore.BinaryFinder

    # Resolve "auto" to preferred GPU backend for the platform
    resolved_backend = resolve_auto_backend(compute_backend)
    path = BinaryFinder.arch_bin_path("sd", resolved_backend)

    # Check if the requested binary exists
    cond do
      File.exists?(path) ->
        path

      true ->
        # Try fallbacks in order: CUDA, then CPU
        fallback =
          BinaryFinder.find_arch_binary("sd", "cuda", fallback_cpu: true)

        if fallback do
          Logger.warning(
            "[sd.cpp] Binary for #{compute_backend} not found, using fallback: #{fallback}"
          )

          fallback
        else
          Logger.error("[sd.cpp] No SD binary found!")
          path
        end
    end
  end

  # Resolve "auto" compute backend to the preferred GPU backend for current platform
  defp resolve_auto_backend("auto") do
    LeaxerCore.ComputeBackend.get_backend()
  end

  defp resolve_auto_backend(backend), do: backend

  defp cleanup_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp kill_os_process(os_pid) do
    Logger.info("[sd.cpp] Attempting to kill OS process #{os_pid}")

    case LeaxerCore.Platform.kill_process(os_pid) do
      {:ok, output} ->
        Logger.info("[sd.cpp] Process #{os_pid} killed successfully: #{inspect(output)}")

      {:error, {output, exit_code}} ->
        Logger.warning(
          "[sd.cpp] Failed to kill process #{os_pid}: exit_code=#{exit_code}, output=#{inspect(output)}"
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

  defp generate_output_path(opts) do
    GenerationHelpers.generate_output_path(opts)
  end

  defp parse_and_broadcast_progress(line, job_id, node_id) do
    case GenerationHelpers.parse_progress(line, @progress_regex) do
      {current_step, total_steps} ->
        phase = if total_steps > 200, do: "loading", else: "inference"

        Logger.info(
          "[sd.cpp] Broadcasting #{phase} progress #{current_step}/#{total_steps} for node_id: #{inspect(node_id)}"
        )

        GenerationHelpers.broadcast_progress(job_id, node_id, current_step, total_steps, phase)

      nil ->
        # Log other output for debugging
        Logger.debug("[sd.cpp] #{line}")
    end
  end

  defp broadcast_completion(job_id, result) do
    GenerationHelpers.broadcast_completion(job_id, result)
  end

  defp broadcast_error(job_id, error) do
    GenerationHelpers.broadcast_error(job_id, error)
  end
end
