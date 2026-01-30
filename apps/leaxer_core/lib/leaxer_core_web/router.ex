defmodule LeaxerCoreWeb.Router do
  use LeaxerCoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LeaxerCoreWeb do
    pipe_through :api

    # Health check for startup readiness
    get "/health", HealthController, :check

    # Node registry
    get "/nodes", NodeController, :index
    get "/nodes/:type", NodeController, :show
    post "/nodes/reload", NodeController, :reload

    # Model management
    get "/models", ModelController, :index
    get "/models/checkpoints", ModelController, :checkpoints
    get "/models/controlnets", ModelController, :controlnets
    get "/models/llms", ModelController, :llms
    get "/models/loras", ModelController, :loras
    get "/models/vaes", ModelController, :vaes
    get "/models/:name", ModelController, :show

    # Workflow file operations (CRUD)
    get "/workflows", WorkflowController, :index
    get "/workflows/:name", WorkflowController, :show
    post "/workflows", WorkflowController, :create
    delete "/workflows/:name", WorkflowController, :delete

    # Workflow validation
    post "/workflow/validate", WorkflowController, :validate

    # Model downloads
    get "/downloads", DownloadController, :index
    get "/downloads/:id", DownloadController, :show
    post "/downloads/start", DownloadController, :start
    delete "/downloads/:id", DownloadController, :cancel

    # Model registry
    get "/registry/models", DownloadController, :registry

    # User paths
    get "/paths", PathsController, :index

    # Serve generated outputs (images, etc.)
    get "/outputs/*path", OutputController, :show

    # Serve temporary preview images
    get "/tmp/*path", OutputController, :show_tmp

    # File uploads
    post "/upload/image", UploadController, :upload_image

    # Serve uploaded input images
    get "/inputs/*path", UploadController, :show

    # System management
    post "/system/restart", SystemController, :restart
    post "/system/cleanup", SystemController, :cleanup

    # User settings
    get "/settings", SettingsController, :index
    put "/settings", SettingsController, :update
    get "/settings/network-info", SettingsController, :network_info
    get "/settings/search-providers", SettingsController, :search_providers
    get "/settings/compute-backends", SettingsController, :compute_backends

    # Chat sessions
    get "/chats", ChatController, :index
    get "/chats/:id", ChatController, :show
    post "/chats", ChatController, :create
    delete "/chats/:id", ChatController, :delete
    put "/chats/:id/rename", ChatController, :rename

    # PDF text extraction
    post "/extract-pdf", ChatController, :extract_pdf
    get "/pdf-available", ChatController, :pdf_available
  end
end
