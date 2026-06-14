# config/runtime.exs — 확장 환경변수 게이트 병합 기준본 (운영/런타임)
#
# phx.new 가 생성한 runtime.exs 의 DATABASE_URL / SECRET_KEY_BASE / PHX_HOST 등 prod 설정은
# 그대로 두고, 아래 확장 게이트 블록을 추가한다.
# 이 파일은 모든 환경에서 실행되므로(import Config; if config_env() == :prod ...),
# 확장 게이트는 config_env 조건 밖(공통 영역)에 두어 dev/prod 모두 환경변수로 제어 가능하게 한다.
#
# 환경변수로 확장을 켠다. 켜려면 해당 인프라(TimescaleDB / MinIO)가 준비되어 있어야 한다.
#
# 출처: 10/runtime.exs + 06 config.snippets + 07 CORE_PATCH.md + 각 애드온 스니펫.

import Config

# ── EXT-1 설비 수집 (TimescaleDB 필요) ─────────────────────────────────────
config :open_mes, OpenMes.Ingest,
  enabled: System.get_env("INGEST_ENABLED", "false") == "true",
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens:
    System.get_env("INGEST_DEVICE_TOKENS", "") |> String.split(",", trim: true)

# ── EXT-2 멀티미디어 (MinIO 필요) ──────────────────────────────────────────
config :open_mes, OpenMes.Media,
  enabled: System.get_env("MEDIA_ENABLED", "false") == "true",
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink,
  bucket: System.get_env("MEDIA_BUCKET", "open-mes-media"),
  watch_roots:
    System.get_env("MEDIA_WATCH_ROOTS", "") |> String.split(",", trim: true)

# ── ex_aws (MinIO) 엔드포인트 — 환경변수로 덮어쓰기 ────────────────────────
config :ex_aws,
  access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
  secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin")

config :ex_aws, :s3,
  scheme: System.get_env("MINIO_SCHEME", "http://"),
  host: System.get_env("MINIO_HOST", "localhost"),
  port: String.to_integer(System.get_env("MINIO_PORT", "9000"))

# ── 애드온 게이트 — 읽기 전용. 운영에서 끄려면 ADDON_*_ENABLED=false ───────
config :open_mes, OpenMes.Addons.WoCsvExport,
  enabled: System.get_env("ADDON_WO_CSV_EXPORT_ENABLED", "true") == "true"

config :open_mes, OpenMes.Addons.DefectStats,
  enabled: System.get_env("ADDON_DEFECT_STATS_ENABLED", "true") == "true"

config :open_mes, OpenMes.Addons.LotQrLabel,
  enabled: System.get_env("ADDON_LOT_QR_LABEL_ENABLED", "true") == "true"

config :open_mes, OpenMes.Addons.EquipmentOee,
  enabled: System.get_env("ADDON_EQUIPMENT_OEE_ENABLED", "true") == "true"

# ⑤ 일일요약은 기본 off(읽기 테이블 전제) — 켜려면 DAILY_SUMMARY_ENABLED=true
config :open_mes, OpenMes.Addons.DailyProductionSummary,
  enabled: System.get_env("DAILY_SUMMARY_ENABLED", "false") == "true"
