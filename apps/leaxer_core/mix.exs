defmodule LeaxerCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :leaxer_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  defp releases do
    [
      leaxer_core: [
        include_erts: true,
        include_executables_for: [:windows],
        applications: [runtime_tools: :permanent],
        strip_beams: true
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {LeaxerCore.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssl, :os_mon, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_pubsub, "~> 2.1"},
      {:libgraph, "~> 0.16"},
      {:cors_plug, "~> 3.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:floki, "~> 0.36"}
      # Bakeware/Burrito have Windows issues, using standard release
      # {:bakeware, "~> 0.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "sync.dlls", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "sync.dlls", "tailwind leaxer_core", "esbuild leaxer_core"],
      "assets.deploy": [
        "tailwind leaxer_core --minify",
        "esbuild leaxer_core --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "sync.dlls": &sync_priv_bin_dlls/1
    ]
  end

  # Ensure DLLs are copied to _build on Windows (Mix doesn't always sync them)
  defp sync_priv_bin_dlls(_) do
    if match?({:win32, _}, :os.type()) do
      src = Path.join([__DIR__, "priv", "bin"])
      build_path = Path.join([__DIR__, "..", "..", "_build", to_string(Mix.env()), "lib", "leaxer_core", "priv", "bin"])
      dest = Path.expand(build_path)

      if File.dir?(src) and File.dir?(dest) do
        src
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".dll"))
        |> Enum.each(fn dll ->
          src_path = Path.join(src, dll)
          dest_path = Path.join(dest, dll)

          if not File.exists?(dest_path) or
               File.stat!(src_path).mtime > File.stat!(dest_path).mtime do
            File.cp!(src_path, dest_path)
            Mix.shell().info("Copied #{dll} to _build")
          end
        end)
      end
    end
  end
end
