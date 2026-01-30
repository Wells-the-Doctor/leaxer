defmodule LeaxerCore.NativeLauncher.Windows do
  @moduledoc """
  Windows-specific native binary launcher with proper DLL search path setup.

  Uses cmd.exe with `cd /d && exe` pattern to ensure the working directory
  is changed BEFORE the executable is spawned. This is critical because
  Windows DLL resolution uses the calling process's state during CreateProcess.
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

    Logger.info("[NativeLauncher.Windows] Spawning: #{native_exe_path}")
    Logger.info("[NativeLauncher.Windows] DLL dir: #{native_bin_dir}")

    # Validate DLLs exist before spawning
    validate_dll_presence(native_bin_dir)

    # Use cmd.exe approach for reliable DLL loading
    spawn_via_cmd(native_exe_path, args, native_bin_dir, additional_env, extra_port_opts)
  end

  defp spawn_via_cmd(exe_path, args, bin_dir, additional_env, extra_port_opts) do
    # Build environment with bin_dir prepended to PATH
    env = build_process_env(bin_dir, additional_env)

    # Escape arguments for cmd.exe
    escaped_args =
      args
      |> Enum.map(&escape_cmd_arg/1)
      |> Enum.join(" ")

    # Build the command: cd to directory, then run executable
    # The && ensures cd succeeds before running the exe
    cmd_command = "cd /d \"#{bin_dir}\" && \"#{exe_path}\" #{escaped_args}"

    Logger.info("[NativeLauncher.Windows] cmd command: #{cmd_command}")

    cmd_exe = System.get_env("COMSPEC") || "C:\\Windows\\System32\\cmd.exe"

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["/c", cmd_command],
        env: env
      ] ++ extra_port_opts

    try do
      port = Port.open({:spawn_executable, cmd_exe}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      Logger.info("[NativeLauncher.Windows] Spawned via cmd.exe, OS PID: #{inspect(os_pid)}")
      {:ok, port, os_pid}
    rescue
      e ->
        Logger.error("[NativeLauncher.Windows] Failed to spawn via cmd: #{inspect(e)}")
        {:error, e}
    end
  end

  # Escape argument for cmd.exe
  defp escape_cmd_arg(arg) when is_binary(arg) do
    if needs_cmd_quoting?(arg) do
      # Escape internal quotes and wrap in quotes
      escaped = String.replace(arg, "\"", "\\\"")
      "\"#{escaped}\""
    else
      arg
    end
  end

  defp needs_cmd_quoting?(arg) do
    String.contains?(arg, [" ", "\t", "&", "|", "<", ">", "^", "%", "(", ")"])
  end

  # Validate that required DLLs are present in the bin directory
  defp validate_dll_presence(bin_dir) do
    critical_dlls = ["llama.dll"]

    Enum.each(critical_dlls, fn dll ->
      dll_path = Path.join(bin_dir, dll) |> to_windows_path()

      if File.exists?(dll_path) do
        Logger.info("[NativeLauncher.Windows] Found critical DLL: #{dll}")
      else
        Logger.error("[NativeLauncher.Windows] CRITICAL: #{dll} not found at #{dll_path}")
        log_bin_dir_contents(bin_dir)
      end
    end)
  end

  defp log_bin_dir_contents(bin_dir) do
    case File.ls(bin_dir) do
      {:ok, files} ->
        Logger.error(
          "[NativeLauncher.Windows] bin_dir contents: #{inspect(Enum.take(files, 20))}"
        )

      {:error, reason} ->
        Logger.error("[NativeLauncher.Windows] Cannot list #{bin_dir}: #{inspect(reason)}")
    end
  end

  @doc """
  Build environment variables for a Windows child process.
  Prepends bin_dir to PATH for DLL discovery.
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
