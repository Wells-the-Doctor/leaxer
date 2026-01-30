defmodule LeaxerCore.Settings do
  @moduledoc """
  Manages user settings stored in config.json.

  Settings are stored in the user's Leaxer data directory at `config.json`.
  This module provides functions to read and write settings.

  ## Settings

  - `network_exposure_enabled` - When true, binds the server to 0.0.0.0 to allow
    LAN access from other devices. Requires app restart to take effect. Default: false.
  """

  require Logger

  @default_settings %{
    "network_exposure_enabled" => false,
    "compute_backend" => "auto"
  }

  @doc """
  Returns the path to the config file.
  """
  def config_path do
    LeaxerCore.Paths.config_file()
  end

  @doc """
  Reads all settings from config.json.
  Returns a map with all settings, using defaults for missing values.
  """
  def all do
    case read_config() do
      {:ok, config} ->
        Map.merge(@default_settings, config)

      {:error, _} ->
        @default_settings
    end
  end

  @doc """
  Gets a single setting value by key.
  Returns the default value if the key doesn't exist.
  """
  def get(key) when is_binary(key) do
    all() |> Map.get(key, Map.get(@default_settings, key))
  end

  def get(key) when is_atom(key) do
    get(Atom.to_string(key))
  end

  @doc """
  Sets a single setting value.
  Returns {:ok, settings} on success or {:error, reason} on failure.
  """
  def set(key, value) when is_binary(key) do
    current = all()
    updated = Map.put(current, key, value)
    write_config(updated)
  end

  def set(key, value) when is_atom(key) do
    set(Atom.to_string(key), value)
  end

  @doc """
  Updates multiple settings at once.
  Returns {:ok, settings} on success or {:error, reason} on failure.
  """
  def update(settings) when is_map(settings) do
    current = all()

    # Convert atom keys to strings
    settings_with_string_keys =
      Enum.reduce(settings, %{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    updated = Map.merge(current, settings_with_string_keys)
    write_config(updated)
  end

  @doc """
  Returns whether network exposure is enabled.
  """
  def network_exposure_enabled? do
    get("network_exposure_enabled") == true
  end

  @doc """
  Returns network information for the settings UI.
  """
  def network_info do
    %{
      network_exposure_enabled: network_exposure_enabled?(),
      local_ips: get_local_ips(),
      current_binding: get_current_binding(),
      backend_port: get_port(),
      frontend_port: get_frontend_port()
    }
  end

  # Private functions

  defp read_config do
    path = config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} when is_map(config) -> {:ok, config}
          {:ok, _} -> {:error, :invalid_format}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, :enoent} ->
        # Config file doesn't exist yet, return empty config
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("[Settings] Failed to read config: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write_config(settings) do
    path = config_path()

    # Ensure directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    case Jason.encode(settings, pretty: true) do
      {:ok, content} ->
        case File.write(path, content) do
          :ok ->
            Logger.info("[Settings] Saved settings to #{path}")
            {:ok, settings}

          {:error, reason} ->
            Logger.error("[Settings] Failed to write config: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[Settings] Failed to encode config: #{inspect(reason)}")
        {:error, {:encode_error, reason}}
    end
  end

  defp get_local_ips do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.flat_map(fn {_name, opts} ->
          opts
          |> Enum.filter(fn
            {:addr, {a, _, _, _}} when a != 127 -> true
            _ -> false
          end)
          |> Enum.map(fn {:addr, ip} -> format_ip(ip) end)
        end)
        |> Enum.filter(&is_private_ip?/1)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp is_private_ip?(ip) when is_binary(ip) do
    # Check for RFC1918 private ranges
    cond do
      String.starts_with?(ip, "192.168.") -> true
      String.starts_with?(ip, "10.") -> true
      String.match?(ip, ~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./) -> true
      true -> false
    end
  end

  defp get_current_binding do
    case Application.get_env(:leaxer_core, LeaxerCoreWeb.Endpoint)[:http][:ip] do
      {0, 0, 0, 0} -> "0.0.0.0"
      {0, 0, 0, 0, 0, 0, 0, 0} -> "::"
      {127, 0, 0, 1} -> "127.0.0.1"
      nil -> "127.0.0.1"
      ip when is_tuple(ip) -> format_ip(ip)
    end
  end

  defp get_port do
    Application.get_env(:leaxer_core, LeaxerCoreWeb.Endpoint)[:http][:port] || 4000
  end

  defp get_frontend_port do
    # Frontend port - defaults to 8888 for Vite dev server
    # Can be overridden via UI_PORT env var
    String.to_integer(System.get_env("UI_PORT", "8888"))
  end
end
