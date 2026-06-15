defmodule OpenMes.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_mes,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {OpenMes.Application, []},
      extra_applications: [:logger, :runtime_tools]
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
      # ── 확장 계약 패키지(설계 30 §3) — 형제 디렉토리 path dep ──────────────
      # 외부 repo 확장이 코어(:open_mes)가 아닌 이 얇은 계약 패키지에만 의존하도록 분리.
      # 계약 안정화 후 Hex publish 예정({:open_mes_extension_api, "~> 0.1"}).
      {:open_mes_extension_api, path: "../open_mes_extension_api"},
      # 외부 repo 확장 증명(설계 30) — deps 이 한 줄만으로 카탈로그·라우트 자동 노출.
      # 코어 소스(router/config/extension/ext.verify)는 수정하지 않는다. 기본 비활성.
      {:open_mes_ext_demo, path: "../open_mes_ext_demo"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      # TODO bump on release to {:phoenix_live_view, "~> 1.0.0"},
      {:phoenix_live_view, "~> 1.0.0-rc.1", override: true},
      {:floki, ">= 0.30.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      # ── AI (23) — ClaudeProvider HTTP. MockProvider 는 미사용(외부 의존 0). ──
      {:req, "~> 0.5"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},

      # ── EXT-1 설비 수집 (06) ────────────────────────────────────────────
      {:broadway, "~> 1.1"},

      # ── EXT-2 멀티미디어 (07) — MinIO(S3 호환) ─────────────────────────
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:file_system, "~> 1.0"},

      # ── 애드온 ──────────────────────────────────────────────────────────
      {:eqrcode, "~> 0.2"}
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
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind open_mes", "esbuild open_mes"],
      "assets.deploy": [
        "tailwind open_mes --minify",
        "esbuild open_mes --minify",
        "phx.digest"
      ]
    ]
  end
end
