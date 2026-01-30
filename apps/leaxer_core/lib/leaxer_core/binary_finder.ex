defmodule LeaxerCore.BinaryFinder do
  @moduledoc """
  Centralized helper for finding binary executables in priv/bin/.

  Provides consistent binary path resolution across the codebase with support for:
  - Platform-specific binary names (Windows .exe extension)
  - Architecture-specific binaries (arm64, x86_64, etc.)
  - Compute backend variants (cpu, cuda, metal)
  - System PATH fallback for common tools

  ## Simple binaries

  For binaries that don't vary by architecture:

      BinaryFinder.priv_bin_path("leaxer-sam")
      # => "/path/to/priv/bin/leaxer-sam" (Unix)
      # => "/path/to/priv/bin/leaxer-sam.exe" (Windows)

  ## Architecture-aware binaries

  For binaries compiled for specific architectures:

      BinaryFinder.arch_bin_path("sd")
      # => "/path/to/priv/bin/sd-aarch64-apple-darwin" (macOS ARM)
      # => "/path/to/priv/bin/sd-x86_64-pc-windows-msvc.exe" (Windows)

      BinaryFinder.arch_bin_path("sd-server", "cuda")
      # => "/path/to/priv/bin/sd-server-x86_64-unknown-linux-gnu-cuda" (Linux with CUDA)

  ## System fallback

  For binaries that can fall back to system PATH:

      BinaryFinder.find_binary("magick", system_fallback: true)
      # Returns bundled path if exists, otherwise "magick" if available in PATH

  """

  require Logger

  @doc """
  Get the path to a simple binary in priv/bin/, with Windows .exe handling.

  This is for binaries that don't have architecture-specific variants.
  The binary name should not include the .exe extension.

  ## Examples

      iex> BinaryFinder.priv_bin_path("leaxer-sam")
      "/path/to/priv/bin/leaxer-sam"  # or with .exe on Windows

      iex> BinaryFinder.priv_bin_path("realesrgan-ncnn-vulkan")
      "/path/to/priv/bin/realesrgan-ncnn-vulkan"  # or with .exe on Windows
  """
  @spec priv_bin_path(String.t()) :: String.t()
  def priv_bin_path(binary_name) do
    base = Path.join([priv_bin_dir(), binary_name])
    add_windows_extension(base)
  end

  @doc """
  Get the path to an architecture-specific binary in priv/bin/.

  Binary name format: `{name}-{arch}` where arch is automatically detected.
  Supports optional compute backend suffix for GPU-accelerated variants.

  ## Arguments

  - `binary_name` - Base name without arch suffix (e.g., "sd", "sd-server", "llama")
  - `compute_backend` - Optional compute backend: "cpu", "cuda", "metal" (default: "cpu")

  ## Examples

      iex> BinaryFinder.arch_bin_path("sd")
      "/path/to/priv/bin/sd-aarch64-apple-darwin"  # macOS ARM

      iex> BinaryFinder.arch_bin_path("sd-server", "cuda")
      "/path/to/priv/bin/sd-server-x86_64-unknown-linux-gnu-cuda"  # Linux CUDA
  """
  @spec arch_bin_path(String.t(), String.t()) :: String.t()
  def arch_bin_path(binary_name, compute_backend \\ "cpu") do
    arch = detect_arch(compute_backend)
    Path.join([priv_bin_dir(), "#{binary_name}-#{arch}"])
  end

  @doc """
  Find a binary, checking bundled location first then system PATH.

  Returns the path to use for executing the binary, or nil if not found.

  ## Options

  - `:system_fallback` - If true, check system PATH when bundled binary not found (default: false)
  - `:system_name` - Name to look for in system PATH if different from binary_name

  ## Examples

      iex> BinaryFinder.find_binary("magick", system_fallback: true)
      "/path/to/priv/bin/magick"  # if bundled exists
      "magick"  # if only system available
      nil  # if neither exists

      iex> BinaryFinder.find_binary("leaxer-sam")
      "/path/to/priv/bin/leaxer-sam"  # if exists
      nil  # if not found
  """
  @spec find_binary(String.t(), keyword()) :: String.t() | nil
  def find_binary(binary_name, opts \\ []) do
    bundled_path = priv_bin_path(binary_name)

    cond do
      File.exists?(bundled_path) ->
        bundled_path

      Keyword.get(opts, :system_fallback, false) ->
        system_name = Keyword.get(opts, :system_name, binary_name)

        if system_binary_available?(system_name) do
          system_name
        else
          nil
        end

      true ->
        nil
    end
  end

  @doc """
  Find an architecture-specific binary with optional fallback.

  Checks for the requested compute backend first, then falls back to CPU variant
  if not found.

  ## Options

  - `:fallback_cpu` - If true, fall back to CPU variant when requested backend not found (default: true)

  ## Examples

      iex> BinaryFinder.find_arch_binary("sd-server", "cuda", fallback_cpu: true)
      "/path/to/priv/bin/sd-server-x86_64-unknown-linux-gnu-cuda"  # if CUDA exists
      "/path/to/priv/bin/sd-server-x86_64-unknown-linux-gnu"  # falls back to CPU
      nil  # if neither exists
  """
  @spec find_arch_binary(String.t(), String.t(), keyword()) :: String.t() | nil
  def find_arch_binary(binary_name, compute_backend \\ "cpu", opts \\ []) do
    primary_path = arch_bin_path(binary_name, compute_backend)

    cond do
      File.exists?(primary_path) ->
        primary_path

      compute_backend != "cpu" and Keyword.get(opts, :fallback_cpu, true) ->
        cpu_path = arch_bin_path(binary_name, "cpu")
        if File.exists?(cpu_path), do: cpu_path, else: nil

      # On macOS ARM, try metal variant when cpu requested but not found
      compute_backend == "cpu" and macos_arm?() ->
        metal_path = arch_bin_path(binary_name, "metal")
        if File.exists?(metal_path), do: metal_path, else: nil

      true ->
        nil
    end
  end

  @doc """
  Check if running on macOS ARM (Apple Silicon).
  """
  @spec macos_arm?() :: boolean()
  def macos_arm? do
    case :os.type() do
      {:unix, :darwin} ->
        sys_arch = :erlang.system_info(:system_architecture) |> to_string()
        String.starts_with?(sys_arch, "aarch64") or String.starts_with?(sys_arch, "arm")

      _ ->
        false
    end
  end

  @doc """
  Check if an architecture-specific binary exists for any supported backend.

  Useful for checking if a feature (like sd-server mode) is available at all.

  ## Examples

      iex> BinaryFinder.any_arch_binary_exists?("sd-server")
      true  # if any variant exists (cpu, cuda, or metal)
  """
  @spec any_arch_binary_exists?(String.t()) :: boolean()
  def any_arch_binary_exists?(binary_name) do
    Enum.any?(["cpu", "cuda", "metal"], fn backend ->
      path = arch_bin_path(binary_name, backend)
      File.exists?(path)
    end)
  end

  @doc """
  Get the priv/bin directory path.

  In dev mode on Windows, returns the source priv/bin path to avoid DLL sync issues.
  The _build directory gets cleaned during recompiles, losing the DLLs.

  ## Examples

      iex> BinaryFinder.priv_bin_dir()
      "/path/to/leaxer_core/priv/bin"
  """
  @spec priv_bin_dir() :: String.t()
  def priv_bin_dir do
    build_priv = Path.join(Application.app_dir(:leaxer_core, "priv"), "bin")

    Logger.debug("[BinaryFinder] build_priv (Application.app_dir): #{build_priv}")

    # On Windows in dev mode, use source priv/bin to avoid DLL sync issues
    # In releases, Mix is not available, so we check for it safely
    path =
      case {mix_env_safe(), :os.type()} do
        {:dev, {:win32, _}} ->
          source_priv = source_priv_bin_dir()
          Logger.debug("[BinaryFinder] dev mode on Windows, source_priv: #{source_priv}")
          # Use source if it has DLLs, otherwise fall back to build
          if File.exists?(Path.join(source_priv, "llama.dll")) do
            Logger.debug("[BinaryFinder] Using source_priv (llama.dll found)")
            source_priv
          else
            Logger.debug("[BinaryFinder] Falling back to build_priv (no llama.dll in source)")
            build_priv
          end

        _ ->
          build_priv
      end

    # Convert to native path format (backslashes on Windows)
    native_path = to_native_path(path)

    # Diagnostic logging for debugging DLL loading issues
    llama_dll_path = Path.join(path, "llama.dll")
    llama_dll_exists = File.exists?(llama_dll_path)

    Logger.info("[BinaryFinder] priv_bin_dir resolved to: #{native_path}")
    Logger.info("[BinaryFinder] llama.dll exists at #{llama_dll_path}: #{llama_dll_exists}")

    # Log directory contents for additional debugging on Windows
    if match?({:win32, _}, :os.type()) do
      case File.ls(path) do
        {:ok, files} ->
          dll_files = Enum.filter(files, &String.ends_with?(&1, ".dll"))
          Logger.info("[BinaryFinder] DLLs in priv_bin_dir: #{inspect(dll_files)}")

        {:error, reason} ->
          Logger.error("[BinaryFinder] Cannot list priv_bin_dir: #{inspect(reason)}")
      end
    end

    native_path
  end

  # Safely get Mix.env(), returning :prod if Mix is not available (in releases)
  defp mix_env_safe do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end

  @doc """
  Get the source priv/bin directory path (not _build).
  """
  @spec source_priv_bin_dir() :: String.t()
  def source_priv_bin_dir do
    # Navigate from this file to priv/bin
    Path.join([__DIR__, "..", "..", "priv", "bin"]) |> Path.expand() |> to_native_path()
  end

  # Convert path to native format (backslashes on Windows)
  defp to_native_path(path) do
    case :os.type() do
      {:win32, _} -> String.replace(path, "/", "\\")
      _ -> path
    end
  end

  @doc """
  Detect the current system architecture string for binary naming.

  Returns a string like "aarch64-apple-darwin", "x86_64-pc-windows-msvc.exe", etc.
  Appends compute backend suffix when provided (e.g., "-cuda", "-metal").

  ## Arguments

  - `compute_backend` - "cpu", "cuda", or "metal" (default: "cpu")

  ## Examples

      iex> BinaryFinder.detect_arch()
      "x86_64-pc-windows-msvc.exe"  # Windows

      iex> BinaryFinder.detect_arch("cuda")
      "x86_64-unknown-linux-gnu-cuda"  # Linux with CUDA
  """
  @spec detect_arch(String.t()) :: String.t()
  def detect_arch(compute_backend \\ "cpu") do
    sys_arch = :erlang.system_info(:system_architecture) |> to_string()

    case :os.type() do
      {:unix, :darwin} ->
        base_arch =
          if String.starts_with?(sys_arch, "aarch64") or String.starts_with?(sys_arch, "arm") do
            "aarch64-apple-darwin"
          else
            "x86_64-apple-darwin"
          end

        case compute_backend do
          "metal" -> base_arch <> "-metal"
          _ -> base_arch
        end

      {:unix, _} ->
        case compute_backend do
          "cuda" -> "x86_64-unknown-linux-gnu-cuda"
          _ -> "x86_64-unknown-linux-gnu"
        end

      {:win32, _} ->
        case compute_backend do
          "cuda" -> "x86_64-pc-windows-msvc-cuda.exe"
          "directml" -> "x86_64-pc-windows-msvc-directml.exe"
          _ -> "x86_64-pc-windows-msvc.exe"
        end
    end
  end

  @doc """
  Check if a binary is available in the system PATH.

  ## Examples

      iex> BinaryFinder.system_binary_available?("magick")
      true  # if ImageMagick is installed
  """
  @spec system_binary_available?(String.t()) :: boolean()
  def system_binary_available?(binary_name) do
    case System.cmd(binary_name, ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    # ErlangError with :enoent occurs when executable not found
    ErlangError -> false
  end

  # Private helpers

  defp add_windows_extension(path) do
    case :os.type() do
      {:win32, _} -> path <> ".exe"
      _ -> path
    end
  end
end
