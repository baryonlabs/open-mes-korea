# config/config.exs — 확장 추가분 병합 기준본 (통합 최종)
#
# phx.new 가 생성한 config.exs 의 보일러플레이트(Repo/Endpoint/esbuild/tailwind/json_library 등)는
# 그대로 두고, 아래 "확장 레지스트리 + 게이트" 블록을 추가한다.
# 파일 끝의 `import_config "#{config_env()}.exs"` 는 반드시 유지(맨 아래에 그대로).
#
# 출처:
#   - :extensions 리스트     : 10/config.exs + 11_addon_* 각 config.snippets.md / INTEGRATION.md
#   - EXT-1/EXT-2 게이트      : 10/config.exs (06 config.snippets / 07 CORE_PATCH 승계)
#   - 애드온 게이트           : 11_addon_* 스니펫(읽기 전용 → 기본 on, 단 ⑤ 일일요약은 기본 off)
#   - ex_aws(MinIO) 정적 설정  : 07 CORE_PATCH.md (런타임 기본값은 runtime.exs)

import Config

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
# 애드온은 읽기 전용 + 인프라 무의존 → 운영상 켜도 안전(기본 on).
# ⑤ 일일 생산 요약만 스니펫상 기본 off(읽기 테이블 전제) → 명시적으로 켤 때만 노출.
config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
config :open_mes, OpenMes.Addons.DefectStats, enabled: true
config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: false

# phx.new 가 생성하는 아래 줄은 파일 끝에 그대로 유지한다:
# import_config "#{config_env()}.exs"
