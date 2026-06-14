# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :open_mes,
  ecto_repos: [OpenMes.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configures the endpoint
config :open_mes, OpenMesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpenMesWeb.ErrorHTML, json: OpenMesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OpenMes.PubSub,
  live_view: [signing_salt: "IigbMMcd"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  open_mes: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  open_mes: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ── 확장 레지스트리: 명시 목록(= 카탈로그 노출 대상, 7개 전체) ──────────────
# "등록(이 리스트 포함) ≠ 활성(enabled?)". 비활성 확장도 카탈로그에 '비활성' 배지로 노출되므로
# 7개를 항상 전부 넣는다. 켜고/끄기는 아래 게이트가 결정한다.
config :open_mes, :extensions, [
  # EXT (인프라 의존, 기본 off)
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  # 애드온 5개 (읽기 전용)
  OpenMes.Addons.WoCsvExport.Extension,
  OpenMes.Addons.DefectStats.Extension,
  OpenMes.Addons.LotQrLabel.Extension,
  OpenMes.Addons.EquipmentOee.Extension,
  OpenMes.Addons.DailyProductionSummary.Extension
]

# ── EXT-1 설비 수집 — 기본 비활성(TimescaleDB 필요) ────────────────────────
config :open_mes, OpenMes.Ingest,
  enabled: false,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: []

# ── EXT-2 멀티미디어 — 기본 비활성(MinIO 필요) ─────────────────────────────
config :open_mes, OpenMes.Media,
  enabled: false,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink

# ── ex_aws (MinIO, S3 호환) — 정적 기본값. 실값은 runtime.exs 가 환경변수로 덮어쓴다 ──
config :ex_aws,
  json_codec: Jason,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000

# ── 애드온 게이트 ──────────────────────────────────────────────────────────
config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
config :open_mes, OpenMes.Addons.DefectStats, enabled: true
config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: false

# AI Provider(설계 23번) — impl: nil 이면 키 존재 여부로 결정(키 없으면 MockProvider 기본).
config :open_mes, OpenMes.Ai.Provider, impl: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
