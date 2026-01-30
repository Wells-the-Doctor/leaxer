defmodule LeaxerCore.ComputeBackend do
  @moduledoc """
  Centralized compute backend detection and configuration.

  Provides GPU detection with caching, user preference management, and
  multi-platform support for CUDA, DirectML, Metal, and ROCm.

  ## Usage

      # Get the resolved backend (user preference + hardware detection)
      backend = LeaxerCore.ComputeBackend.get_backend()
      # => "cuda" | "metal" | "directml" | "rocm" | "cpu"

      # List all available backends for current platform
      backends = LeaxerCore.ComputeBackend.available_backends()
      # => ["cpu", "cuda"] on Windows with NVIDIA GPU

      # Get GPU info for frontend display
      info = LeaxerCore.ComputeBackend.gpu_info()

  ## User Configuration

  Users can set their preferred backend in settings (config.json):

      {"compute_backend": "auto"}  # Auto-detect best backend (default)
      {"compute_backend": "cuda"}  # Force CUDA
      {"compute_backend": "cpu"}   # Force CPU-only

  If the preferred backend is not available, falls back to auto-detection.
  """

  use Agent
  require Logger

  @valid_backends ~w(auto cpu cuda metal directml rocm)

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Get the resolved backend based on user preference and hardware detection.

  Returns "cuda", "metal", "directml", "rocm", or "cpu".
  """
  @spec get_backend() :: String.t()
  def get_backend do
    pref = LeaxerCore.Settings.get("compute_backend") || "auto"
    resolve_backend(pref)
  end

  @doc """
  List all available backends for the current platform.

  Returns a list of backend names that are actually usable on this system.
  """
  @spec available_backends() :: [String.t()]
  def available_backends do
    cached(:available, fn ->
      case :os.type() do
        {:unix, :darwin} -> detect_macos_backends()
        {:win32, _} -> detect_windows_backends()
        {:unix, _} -> detect_linux_backends()
      end
    end)
  end

  @doc """
  Get GPU information for frontend display.

  Returns a map with:
  - `:nvidia` - NVIDIA GPU info (if available)
  - `:amd` - AMD GPU info (if available)
  - `:apple` - Apple Silicon/Metal info (if available)
  - `:platform` - Current platform name
  """
  @spec gpu_info() :: map()
  def gpu_info do
    %{
      nvidia: nvidia_info(),
      amd: amd_info(),
      apple: metal_info(),
      platform: platform_name()
    }
  end

  @doc """
  Check if a specific backend is available on this system.
  """
  @spec backend_available?(String.t()) :: boolean()
  def backend_available?(backend) when backend in @valid_backends do
    backend in available_backends()
  end

  def backend_available?(_), do: false

  @doc """
  Clear the detection cache. Useful for re-detecting after hardware changes.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Agent.update(__MODULE__, fn _ -> %{} end)
    :ok
  end

  @doc """
  Returns the list of valid backend names.
  """
  @spec valid_backends() :: [String.t()]
  def valid_backends, do: @valid_backends

  # Platform-specific backend detection

  defp detect_windows_backends do
    backends = ["cpu"]
    backends = if cuda_available?(), do: backends ++ ["cuda"], else: backends
    backends = if directml_available?(), do: backends ++ ["directml"], else: backends
    backends
  end

  defp detect_linux_backends do
    backends = ["cpu"]
    backends = if cuda_available?(), do: backends ++ ["cuda"], else: backends
    backends = if rocm_available?(), do: backends ++ ["rocm"], else: backends
    backends
  end

  defp detect_macos_backends do
    if apple_silicon?(), do: ["cpu", "metal"], else: ["cpu"]
  end

  # Hardware detection functions

  defp cuda_available? do
    cached(:cuda, fn ->
      case System.cmd("nvidia-smi", ["-L"], stderr_to_stdout: true) do
        {output, 0} -> String.contains?(output, "GPU")
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  defp directml_available? do
    cached(:directml, fn ->
      # Check if DirectML binary exists
      bin_path = LeaxerCore.BinaryFinder.arch_bin_path("llama-server", "directml")
      File.exists?(bin_path)
    end)
  end

  defp rocm_available? do
    cached(:rocm, fn ->
      case System.cmd("rocm-smi", ["--version"], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  defp apple_silicon? do
    cached(:apple_silicon, fn ->
      case :os.type() do
        {:unix, :darwin} ->
          arch = :erlang.system_info(:system_architecture) |> to_string()
          String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm")

        _ ->
          false
      end
    end)
  end

  # GPU info functions

  defp nvidia_info do
    if cuda_available?() do
      cached(:nvidia_info, fn ->
        case System.cmd("nvidia-smi", ["--query-gpu=name,memory.total", "--format=csv,noheader"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            gpus =
              output
              |> String.trim()
              |> String.split("\n")
              |> Enum.map(fn line ->
                case String.split(line, ", ") do
                  [name, memory] -> %{name: String.trim(name), memory: String.trim(memory)}
                  [name] -> %{name: String.trim(name), memory: "unknown"}
                  _ -> nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            %{available: true, gpus: gpus}

          _ ->
            %{available: false, gpus: []}
        end
      end)
    else
      %{available: false, gpus: []}
    end
  rescue
    _ -> %{available: false, gpus: []}
  end

  defp amd_info do
    if rocm_available?() do
      cached(:amd_info, fn ->
        case System.cmd("rocm-smi", ["--showproductname"], stderr_to_stdout: true) do
          {output, 0} ->
            # Parse ROCm output for GPU names
            gpus =
              output
              |> String.split("\n")
              |> Enum.filter(&String.contains?(&1, "GPU"))
              |> Enum.map(fn line -> %{name: String.trim(line)} end)

            %{available: true, gpus: gpus}

          _ ->
            %{available: false, gpus: []}
        end
      end)
    else
      %{available: false, gpus: []}
    end
  rescue
    _ -> %{available: false, gpus: []}
  end

  defp metal_info do
    if apple_silicon?() do
      cached(:metal_info, fn ->
        # Get macOS model identifier
        case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
          {output, 0} ->
            %{available: true, chip: String.trim(output)}

          _ ->
            %{available: true, chip: "Apple Silicon"}
        end
      end)
    else
      %{available: false, chip: nil}
    end
  rescue
    _ -> %{available: false, chip: nil}
  end

  defp platform_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:win32, _} -> "Windows"
      {:unix, :linux} -> "Linux"
      {:unix, os} -> to_string(os)
      _ -> "Unknown"
    end
  end

  # Backend resolution

  defp resolve_backend("auto"), do: detect_best_backend()

  defp resolve_backend(pref) when pref in @valid_backends do
    if pref in available_backends() do
      pref
    else
      Logger.warning(
        "[ComputeBackend] Preferred backend '#{pref}' not available, using auto-detection"
      )

      detect_best_backend()
    end
  end

  defp resolve_backend(invalid) do
    Logger.warning("[ComputeBackend] Invalid backend '#{inspect(invalid)}', using auto-detection")
    detect_best_backend()
  end

  defp detect_best_backend do
    available = available_backends()

    cond do
      "cuda" in available -> "cuda"
      "metal" in available -> "metal"
      "directml" in available -> "directml"
      "rocm" in available -> "rocm"
      true -> "cpu"
    end
  end

  # Caching helper

  defp cached(key, fun) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil ->
        result = fun.()
        Agent.update(__MODULE__, &Map.put(&1, key, result))
        result

      cached_value ->
        cached_value
    end
  rescue
    # Agent might not be started yet during app initialization
    _ -> fun.()
  end
end
