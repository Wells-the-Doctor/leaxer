defmodule LeaxerCore.NativeLauncher.Windows do
  @moduledoc """
  Windows-specific native binary launcher with proper DLL search path setup.

  Uses a batch file wrapper to ensure the working directory is changed BEFORE
  the executable is spawned. This is critical because Windows DLL resolution
  uses the calling process's state during CreateProcess.

  ## The Problem

  Windows DLL loader resolves dependencies during `CreateProcess`, BEFORE the
  child process starts. Erlang's Port.open `cd:` option sets the working
  directory AFTER process creation (too late for DLL resolution).

  ## The Solution

  Create a temporary batch file that:
  1. Changes to the bin directory with `cd /d`
  2. Runs the executable with all arguments
  3. Exits with the executable's exit code

  This works because:
  1. The batch file changes the working directory before spawning the child
  2. DLLs in the bin directory are found via the "current directory" search
  3. We also prepend bin_dir to PATH as a fallback
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

    # Use batch file approach (most reliable for Windows DLL loading)
    spawn_via_batch(native_exe_path, args, native_bin_dir, additional_env, extra_port_opts)
  end

  defp spawn_via_batch(exe_path, args, bin_dir, additional_env, extra_port_opts) do
    env = build_process_env(bin_dir, additional_env)

    # Create a temporary batch file
    batch_content = build_batch_content(exe_path, args, bin_dir)
    batch_path = create_temp_batch_file(batch_content)

    Logger.debug("[NativeLauncher.Windows] Batch file: #{batch_path}")
    Logger.debug("[NativeLauncher.Windows] Batch content:\n#{batch_content}")
    log_path_env(env)

    cmd_exe = System.get_env("COMSPEC") || "C:\\Windows\\System32\\cmd.exe"

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["/c", batch_path],
        env: env
      ] ++ extra_port_opts

    try do
      port = Port.open({:spawn_executable, cmd_exe}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      Logger.info("[NativeLauncher.Windows] Spawned via batch file, OS PID: #{inspect(os_pid)}")
      {:ok, port, os_pid}
    rescue
      e ->
        Logger.error("[NativeLauncher.Windows] Failed to spawn via batch: #{inspect(e)}")
        # Clean up batch file on error
        File.rm(batch_path)
        {:error, e}
    end
  end

  defp build_batch_content(exe_path, args, bin_dir) do
    # Escape arguments for batch file
    escaped_args =
      args
      |> Enum.map(&escape_batch_arg/1)
      |> Enum.join(" ")

    """
    @echo off
    cd /d "#{bin_dir}"
    if errorlevel 1 (
      echo Failed to change directory to #{bin_dir}
      exit /b 1
    )
    "#{exe_path}" #{escaped_args}
    exit /b %errorlevel%
    """
  end

  defp create_temp_batch_file(content) do
    # Use a unique filename in temp directory
    temp_dir = System.tmp_dir!()
    unique_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    batch_path = Path.join(temp_dir, "leaxer_launcher_#{unique_id}.bat")

    # Write with Windows line endings
    windows_content = String.replace(content, "\n", "\r\n")
    File.write!(batch_path, windows_content)

    to_windows_path(batch_path)
  end

  # Escape argument for batch file
  # Batch files use ^ as escape character and " for quoting
  defp escape_batch_arg(arg) when is_binary(arg) do
    if needs_batch_quoting?(arg) do
      # Escape internal quotes and special chars, wrap in quotes
      escaped =
        arg
        |> String.replace("^", "^^")
        |> String.replace("\"", "^\"")
        |> String.replace("%", "%%")

      "\"#{escaped}\""
    else
      arg
    end
  end

  # Check if argument needs quoting for batch file
  defp needs_batch_quoting?(arg) do
    String.contains?(arg, [" ", "\t", "&", "|", "<", ">", "^", "%", "(", ")", "\""])
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
