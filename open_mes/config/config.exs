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

# ── 확장 발견 모드(설계 30 §2.4) ──────────────────────────────────────────
# :auto   — 로드된 OTP 앱을 스캔해 Extension behaviour 구현을 자동 발견(deps 한 줄로 끝).
#           외부 repo 확장이 코어 수정 0 으로 붙는다(목표 상태 §1).
# :manual — 아래 :extensions 명시 목록만 사용(되돌리기 포인트 — 완전 보수적).
# escape hatch: :extra_extensions(강제 등록) / :exclude_extensions(제외) 는 두 모드 공통.
config :open_mes, :extension_discovery, :auto

# ── 확장 레지스트리: 명시 목록(:manual 모드 또는 :auto 미발견 보강용) ──────────
# :auto 모드에선 자동 발견이 이 목록을 대체하지만, :manual 로 되돌리거나 발견 못 한 모듈을
# 보강(:extra_extensions)할 때를 위해 단일 진실 목록으로 유지한다.
# "등록(노출 대상) ≠ 활성(enabled?)". 비활성 확장도 카탈로그에 '비활성' 배지로 노출된다.
config :open_mes, :extensions, [
  # EXT (인프라 의존, 기본 off)
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  # 애드온 5개 (읽기 전용)
  OpenMes.Addons.WoCsvExport.Extension,
  OpenMes.Addons.DefectStats.Extension,
  OpenMes.Addons.LotQrLabel.Extension,
  OpenMes.Addons.EquipmentOee.Extension,
  OpenMes.Addons.DailyProductionSummary.Extension,
  # EXT-5 연동 허브 (integration)
  OpenMes.Connect.DureClaw.Extension
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

# ── EXT-5 연동 허브 게이트 (DureClaw) — 버스 주소는 env BUS_URL/OAH_SECRET ──
config :open_mes, OpenMes.Connect.DureClaw, enabled: true

# AI Provider(설계 23번) — impl: nil 이면 키 존재 여부로 결정(키 없으면 MockProvider 기본).
config :open_mes, OpenMes.Ai.Provider, impl: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
