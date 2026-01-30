defmodule LeaxerCoreWeb.SettingsController do
  @moduledoc """
  REST API controller for user settings.

  Provides endpoints for reading and updating user settings stored in config.json.
  """
  use LeaxerCoreWeb, :controller

  alias LeaxerCore.Settings
  alias LeaxerCore.Services.WebSearch

  @doc """
  GET /api/settings

  Returns all settings from config.json.
  """
  def index(conn, _params) do
    settings = Settings.all()

    conn
    |> put_status(:ok)
    |> json(settings)
  end

  @doc """
  PUT /api/settings

  Updates settings. Accepts a JSON body with key-value pairs to update.
  Returns the updated settings and indicates if a restart is required.

  Settings that require restart:
  - network_exposure_enabled
  """
  def update(conn, params) do
    # Track if any restart-required settings changed
    current = Settings.all()
    restart_required_keys = ["network_exposure_enabled"]

    restart_required =
      Enum.any?(restart_required_keys, fn key ->
        Map.has_key?(params, key) and params[key] != current[key]
      end)

    case Settings.update(params) do
      {:ok, updated_settings} ->
        conn
        |> put_status(:ok)
        |> json(%{
          settings: updated_settings,
          restart_required: restart_required
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "Failed to update settings",
          reason: inspect(reason)
        })
    end
  end

  @doc """
  GET /api/settings/network-info

  Returns network information including:
  - network_exposure_enabled: current setting value
  - local_ips: list of local IP addresses
  - current_binding: what IP the server is currently bound to
  - port: the server port
  """
  def network_info(conn, _params) do
    info = Settings.network_info()

    conn
    |> put_status(:ok)
    |> json(info)
  end

  @doc """
  GET /api/settings/search-providers

  Returns available web search providers for the chat internet feature.
  """
  def search_providers(conn, _params) do
    providers = WebSearch.available_providers()

    conn
    |> put_status(:ok)
    |> json(%{providers: providers})
  end

  @doc """
  GET /api/settings/compute-backends

  Returns available compute backends for the current platform.
  Includes:
  - available_backends: List of available backends on this system
  - current_backend: The resolved backend being used
  - user_preference: The user's setting value (may be "auto")
  - gpu_info: Detailed GPU hardware information
  """
  def compute_backends(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{
      available_backends: LeaxerCore.ComputeBackend.available_backends(),
      current_backend: LeaxerCore.ComputeBackend.get_backend(),
      user_preference: Settings.get("compute_backend") || "auto",
      gpu_info: LeaxerCore.ComputeBackend.gpu_info()
    })
  end
end
