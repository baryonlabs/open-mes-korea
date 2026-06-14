# config/runtime.exs — 운영/환경변수 게이트 (설계 §4.2, §4.4)
#
# 이 파일은 phx.new 가 생성한 runtime.exs 위에 **확장 환경변수 게이트만 추가/병합**하는
# 기준이다. phx.new 가 만드는 DATABASE_URL / SECRET_KEY_BASE / PHX_HOST 등 prod 설정은
# 그대로 두고, 아래 확장 게이트 블록을 추가한다.
#
# 환경변수로 확장을 켠다. 켜려면 해당 인프라(TimescaleDB / MinIO)가 준비되어 있어야 한다.

import Config

# ── EXT-1 설비 수집(06 config.snippets.md 승계) ──────────────────────────
# TimescaleDB 가 설치된 DB 여야 한다(enable_timescaledb 마이그레이션).
config :open_mes, OpenMes.Ingest,
  enabled: System.get_env("INGEST_ENABLED", "false") == "true",
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens:
    System.get_env("INGEST_DEVICE_TOKENS", "") |> String.split(",", trim: true)

# ── EXT-2 멀티미디어(07 CORE_PATCH.md 승계) ──────────────────────────────
# MINIO_* / MEDIA_* 로 object storage 접속 + watch 루트를 설정한다.
config :open_mes, OpenMes.Media,
  enabled: System.get_env("MEDIA_ENABLED", "false") == "true",
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink,
  bucket: System.get_env("MEDIA_BUCKET", "open-mes-media"),
  watch_roots:
    System.get_env("MEDIA_WATCH_ROOTS", "") |> String.split(",", trim: true)

# ── 애드온 게이트(애드온 통합 시 추가) ───────────────────────────────────
# 애드온은 읽기 전용 + 인프라 무의존이라 기본 on 이어도 안전하다(설계 §5).
# 운영에서 끄려면 ADDON_*_ENABLED=false 로 내린다.
# config :open_mes, OpenMes.Addons.WoCsvExport,
#   enabled: System.get_env("ADDON_WO_CSV_EXPORT_ENABLED", "true") == "true"
# config :open_mes, OpenMes.Addons.DefectStats,
#   enabled: System.get_env("ADDON_DEFECT_STATS_ENABLED", "true") == "true"
# config :open_mes, OpenMes.Addons.LotQrLabel,
#   enabled: System.get_env("ADDON_LOT_QR_LABEL_ENABLED", "true") == "true"
# config :open_mes, OpenMes.Addons.EquipmentOee,
#   enabled: System.get_env("ADDON_EQUIPMENT_OEE_ENABLED", "true") == "true"
# config :open_mes, OpenMes.Addons.DailyProductionSummary,
#   enabled: System.get_env("ADDON_DAILY_SUMMARY_ENABLED", "true") == "true"
