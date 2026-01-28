defmodule LeaxerCore.Models.Registry do
  @moduledoc """
  GenServer for managing and caching remote model registry.

  The registry fetches model metadata from a remote URL with fallback to local registry.
  All data is cached in ETS for fast lookup across the application.

  ## Architecture

  - **Remote First**: Attempts to fetch from remote registry_url on startup and refresh
  - **Local Fallback**: Uses priv/registry/models.json if remote fails
  - **ETS Cache**: All registry data cached for fast lookups
  - **Categories**: Organizes models by type (checkpoints, loras, vaes, controlnets, llms)

  ## Supervision

  - **Restart**: Permanent (always restarted)
  - **Strategy**: Part of main supervision tree with `:one_for_one`
  - **ETS Table**: `:model_registry` for cached lookups

  ## Failure Modes

  - **Remote fetch fails**: Falls back to local priv/registry/models.json.
  - **Local fallback fails**: Registry remains empty, lookups return errors.
  - **Crash after data loaded**: ETS table lost, re-fetched on restart.
  - **Periodic refresh fails**: Keeps existing cached data, logs warning.

  ## State Recovery

  On restart, the GenServer re-creates the ETS table and triggers an async
  fetch of registry data. Until data loads, `get_all/0` returns `{:error, :not_loaded}`.

  ## Registry Schema

  Each model entry contains:
  - `id` - Unique identifier for the model
  - `name` - Human-readable display name
  - `category` - Model category (checkpoint/lora/vae/controlnet/llm/etc)
  - `source` - Source platform (huggingface/civitai/local)
  - `url` - Download URL for the model file
  - `filename` - Target filename for download
  - `size_bytes` - File size in bytes
  - `description` - Model description and use case
  - `tags` - Array of searchable tags
  - `recommended` - Boolean indicating if this is a recommended model

  ## Usage

      # Get all models
      LeaxerCore.Models.Registry.get_all()

      # Get models by category
      LeaxerCore.Models.Registry.get_by_category("checkpoints")

      # Get specific model
      LeaxerCore.Models.Registry.get_model("sdxl-base-1.0")

      # Refresh from remote (async)
      LeaxerCore.Models.Registry.refresh()

  ## ETS Concurrency Model

  **Table**: `:model_registry`

  **Configuration**: `:set`, `:public`, `:named_table` (no concurrency flags)

  ### Access Pattern

  - **Readers**: `get_all/0`, `get_by_category/1`, `get_model/1` (direct ETS lookups)
  - **Writers**: GenServer during init and periodic/manual refresh

  ### Concurrency Guarantees

  - **Read safety**: Reads are atomic for single-key lookups. The entire registry
    is stored under one key (`:registry_data`), so each read sees a consistent snapshot.
  - **Write safety**: All writes go through GenServer message handlers. Updates
    only occur during initial load and hourly refresh.
  - **No read_concurrency flag**: Acceptable because reads are infrequent (model
    selection UI) and the data rarely changes (hourly refresh).

  ### Operations

  | Operation | Access | Frequency | Notes |
  |-----------|--------|-----------|-------|
  | `get_all/0` | Read | Low | Direct ETS lookup |
  | `get_by_category/1` | Read | Low | Calls get_all internally |
  | `get_model/1` | Read | Low | Calls get_all internally |
  | `update_registry/3` | Write | Rare | Hourly refresh or manual |

  ### Single-Key Design

  All registry data is stored under a single key (`:registry_data`). This
  simplifies the concurrency model: each read or write is atomic. There are
  no multi-key transactions or partial update scenarios.

  ### Refresh Behavior

  The registry refreshes automatically every hour via `Process.send_after/3`.
  During refresh, the GenServer fetches remote data and atomically replaces
  the ETS entry. Concurrent readers will see either the old or new data,
  never a partial state.
  """

  use GenServer
  require Logger

  # Remote registry URL (configurable via application env)
  @default_registry_url "https://raw.githubusercontent.com/leaxer-ai/leaxer-model-registry/main/registry.json"
  @ets_table :model_registry

  # Get local registry path at runtime (not compile time)
  defp local_registry_path do
    Application.app_dir(:leaxer_core, "priv/registry/models.json")
  end

  # Refresh every hour
  @refresh_interval :timer.hours(1)

  defstruct [
    :registry_data,
    :last_updated,
    :source
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get all models from the registry.

  Returns a map with category keys and model arrays as values:
  ```
  %{
    "checkpoints" => [...],
    "loras" => [...],
    "vaes" => [...],
    "controlnets" => [...],
    "llms" => [...]
  }
  ```
  """
  def get_all do
    case :ets.lookup(@ets_table, :registry_data) do
      [{:registry_data, data}] -> {:ok, data}
      [] -> {:error, :not_loaded}
    end
  end

  @doc """
  Get models by category.

  ## Parameters

  - `category` - Category name (checkpoints/loras/vaes/controlnets/llms/etc)

  ## Returns

  - `{:ok, models}` - List of models in the category
  - `{:error, :category_not_found}` - Category doesn't exist
  - `{:error, :not_loaded}` - Registry not loaded
  """
  def get_by_category(category) when is_binary(category) do
    case get_all() do
      {:ok, registry} ->
        case Map.get(registry, category) do
          nil -> {:error, :category_not_found}
          models -> {:ok, models}
        end

      error ->
        error
    end
  end

  @doc """
  Get a specific model by ID.

  Searches across all categories for the model with the given ID.

  ## Parameters

  - `model_id` - Unique model identifier

  ## Returns

  - `{:ok, model}` - Model data if found
  - `{:error, :model_not_found}` - Model doesn't exist
  - `{:error, :not_loaded}` - Registry not loaded
  """
  def get_model(model_id) when is_binary(model_id) do
    case get_all() do
      {:ok, registry} ->
        # Search all categories and include category in result
        found =
          Enum.find_value(registry, fn {category, models} ->
            case Enum.find(models, fn model -> model["id"] == model_id end) do
              nil -> nil
              model -> {category, model}
            end
          end)

        case found do
          nil -> {:error, :model_not_found}
          {category, model} -> {:ok, Map.put(model, "category", category)}
        end

      error ->
        error
    end
  end

  @doc """
  Refresh the registry from remote source.

  Attempts to fetch the latest registry from the remote URL. If successful,
  updates the ETS cache. If failed, keeps existing data.

  This operation is asynchronous and returns immediately.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc """
  Get registry status and metadata.

  Returns information about the current registry state including source,
  last updated time, and total model counts.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:set, :public, :named_table])

    # Schedule periodic refresh
    Process.send_after(self(), :periodic_refresh, @refresh_interval)

    # Load initial registry data
    state = %__MODULE__{
      registry_data: nil,
      last_updated: nil,
      source: nil
    }

    # Fetch initial data asynchronously
    send(self(), :initial_load)

    {:ok, state}
  end

  @impl true
  def handle_info(:initial_load, state) do
    # Check if local-only mode is enabled (for development)
    local_only? = Application.get_env(:leaxer_core, :model_registry_local_only, false)

    if local_only? do
      # Local-only mode: skip remote fetch
      case load_local_registry() do
        {:ok, data} ->
          new_state = update_registry(state, data, "local")
          Logger.info("Model registry loaded from local file (local-only mode)")
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("Failed to load local registry: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      # Remote-first mode: try remote, fallback to local
      case fetch_remote_registry() do
        {:ok, data, source} ->
          new_state = update_registry(state, data, source)
          Logger.info("Model registry loaded successfully from #{source}")
          {:noreply, new_state}

        {:error, reason} ->
          Logger.warning("Failed to load remote registry: #{inspect(reason)}")

          case load_local_registry() do
            {:ok, data} ->
              new_state = update_registry(state, data, "local")
              Logger.info("Model registry loaded from local fallback")
              {:noreply, new_state}

            {:error, local_reason} ->
              Logger.error("Failed to load local registry fallback: #{inspect(local_reason)}")
              {:noreply, state}
          end
      end
    end
  end

  @impl true
  def handle_info(:periodic_refresh, state) do
    # Schedule next refresh
    Process.send_after(self(), :periodic_refresh, @refresh_interval)

    # Skip periodic refresh in local-only mode
    local_only? = Application.get_env(:leaxer_core, :model_registry_local_only, false)

    if local_only? do
      {:noreply, state}
    else
      # Attempt refresh (silent, don't log failures for periodic refresh)
      case fetch_remote_registry() do
        {:ok, data, source} ->
          new_state = update_registry(state, data, source)
          {:noreply, new_state}

        {:error, _reason} ->
          # Keep existing data on periodic refresh failure
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    # Manual refresh requested
    case fetch_remote_registry() do
      {:ok, data, source} ->
        new_state = update_registry(state, data, source)
        Logger.info("Registry refreshed successfully from #{source}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Manual registry refresh failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    model_counts = get_model_counts(state.registry_data)

    status = %{
      loaded: not is_nil(state.registry_data),
      source: state.source,
      last_updated: state.last_updated,
      model_counts: model_counts
    }

    {:reply, status, state}
  end

  # Private Functions

  defp fetch_remote_registry do
    registry_url = Application.get_env(:leaxer_core, :model_registry_url, @default_registry_url)

    case :httpc.request(:get, {String.to_charlist(registry_url), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, data} -> {:ok, data, "remote"}
          error -> error
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_error, status}}

      error ->
        error
    end
  end

  defp load_local_registry do
    path = local_registry_path()
    Logger.debug("Loading local registry from: #{path}")

    case File.read(path) do
      {:ok, content} ->
        Jason.decode(content)

      error ->
        error
    end
  end

  defp update_registry(state, registry_data, source) do
    # Update ETS cache
    :ets.insert(@ets_table, {:registry_data, registry_data})

    # Update state
    %{state | registry_data: registry_data, last_updated: DateTime.utc_now(), source: source}
  end

  defp get_model_counts(nil), do: %{}

  defp get_model_counts(registry_data) do
    registry_data
    |> Map.take([
      "checkpoints",
      "loras",
      "vaes",
      "controlnets",
      "llms",
      "text_encoders",
      "upscalers"
    ])
    |> Enum.into(%{}, fn {category, models} ->
      {category, length(models)}
    end)
  end
end
