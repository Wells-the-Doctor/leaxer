defmodule LeaxerCore.NativeLauncher.Windows do
  @moduledoc """
  Windows-specific native binary launcher with proper DLL search path setup.

  Spawns executables directly via Port.open with bin_dir prepended to PATH,
  allowing Windows to find DLLs via the PATH environment variable.

  ## DLL Search Order (Windows with SafeDllSearchMode)

  1. DLL Redirection / API sets / SxS manifest
  2. Known DLLs
  3. Application directory (where the .exe is located)
  4-6. System directories
  7. Current directory
  8. PATH environment variable

  Since the executable and DLLs are in the same directory (bin_dir), Windows
  should find them via "Application directory" (#3). We also prepend bin_dir
  to PATH as a fallback (#8).
  """

  require Logger

  @spec spawn_executable(String.t(), [String.t()], keyword()) ::
          {:ok, port(), non_neg_integer() | nil} | {:error, term()}
  def spawn_executable(exe_path, args, opts \\ []) do
    bin_dir = Keyword.get(opts, :bin_dir) || Path.dirname(exe_path)
    additional_env = Keyword.get(opts, :env, [])
    extra_port_opts = Keyword.get(opts, :port_opts, [])

    native_bin_dir = to_windows_path(bin_dir)
    native_exe_path = to_windows_path(exe_path)

    Logger.debug("[NativeLauncher.Windows] Spawning: #{native_exe_path}")
    Logger.debug("[NativeLauncher.Windows] DLL dir: #{native_bin_dir}")

    # Validate DLLs exist before spawning
    validate_dll_presence(native_bin_dir)

    # Direct spawn with PATH set - cleanest approach
    spawn_direct(native_exe_path, args, native_bin_dir, additional_env, extra_port_opts)
  end

  defp spawn_direct(exe_path, args, bin_dir, additional_env, extra_port_opts) do
    # Build environment with bin_dir prepended to PATH
    env = build_process_env(bin_dir, additional_env)

    Logger.debug("[NativeLauncher.Windows] Direct spawn: #{exe_path}")
    Logger.debug("[NativeLauncher.Windows] Args: #{inspect(args)}")
    log_path_env(env)

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: env,
        cd: bin_dir
      ] ++ extra_port_opts

    try do
      port = Port.open({:spawn_executable, exe_path}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      Logger.info("[NativeLauncher.Windows] Spawned directly, OS PID: #{inspect(os_pid)}")
      {:ok, port, os_pid}
    rescue
      e ->
        Logger.error("[NativeLauncher.Windows] Failed to spawn: #{inspect(e)}")
        {:error, e}
    end
  end

  # Log PATH environment variable for debugging
  defp log_path_env(env) do
    {_, path_value} = Enum.find(env, {nil, ~c""}, fn {k, _} -> k == ~c"PATH" end)
    path_str = to_string(path_value)
    path_preview = String.slice(path_str, 0, 300)
    Logger.debug("[NativeLauncher.Windows] PATH (first 300 chars): #{path_preview}")
  end

  # Validate that required DLLs are present in the bin directory
  # This provides clear error messages when DLLs are missing
  defp validate_dll_presence(bin_dir) do
    # Critical DLLs for llama.cpp - llama.dll is the main one
    critical_dlls = ["llama.dll"]

    # CUDA-related DLLs (optional but logged if missing when CUDA is expected)
    cuda_dlls = ["ggml-cuda.dll", "cublas64_12.dll", "cublasLt64_12.dll", "cudart64_12.dll"]

    # Check critical DLLs
    Enum.each(critical_dlls, fn dll ->
      dll_path = Path.join(bin_dir, dll)

      if File.exists?(dll_path) do
        Logger.debug("[NativeLauncher.Windows] Found critical DLL: #{dll}")
      else
        Logger.error("[NativeLauncher.Windows] CRITICAL: #{dll} not found at #{dll_path}")
        log_bin_dir_contents(bin_dir)
      end
    end)

    # Log CUDA DLL status (not critical, just informational)
    cuda_present =
      Enum.filter(cuda_dlls, fn dll ->
        File.exists?(Path.join(bin_dir, dll))
      end)

    if cuda_present != [] do
      Logger.info("[NativeLauncher.Windows] CUDA DLLs present: #{inspect(cuda_present)}")
    end
  end

  defp log_bin_dir_contents(bin_dir) do
    case File.ls(bin_dir) do
      {:ok, files} ->
        Logger.error("[NativeLauncher.Windows] bin_dir contents: #{inspect(Enum.take(files, 20))}")

      {:error, reason} ->
        Logger.error("[NativeLauncher.Windows] Cannot list #{bin_dir}: #{inspect(reason)}")
    end
  end

  @doc """
  Build environment variables for a Windows child process.

  Prepends bin_dir to PATH and sets GGML_BACKEND_DIR for CUDA backend discovery.
  """
  @spec build_process_env(String.t(), [{String.t(), String.t()}]) :: [{charlist(), charlist()}]
  def build_process_env(bin_dir, additional_env \\ []) do
    base_env =
      System.get_env()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    current_path = System.get_env("PATH") || ""
    new_path = "#{bin_dir};#{current_path}"

    base_env
    |> Enum.reject(fn {k, _} -> k == ~c"PATH" end)
    |> Kernel.++([
      {~c"PATH", String.to_charlist(new_path)},
      {~c"GGML_BACKEND_DIR", String.to_charlist(bin_dir)}
    ])
    |> Kernel.++(
      Enum.map(additional_env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)
    )
  end

  defp to_windows_path(path) when is_binary(path), do: String.replace(path, "/", "\\")
  defp to_windows_path(nil), do: nil
end
