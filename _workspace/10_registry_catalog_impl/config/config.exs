# config/config.exs — 통합 config (설계 §5)
#
# 이 파일은 phx.new 가 생성한 config.exs 위에 **확장 관련 블록만 추가/병합**하는 기준이다.
# phx.new 가 만드는 Repo/Endpoint/esbuild/tailwind 등 보일러플레이트 설정은 그대로 두고,
# 아래 "확장 레지스트리 + 게이트" 블록을 추가한다.
#
# 통합 순서(설계 §4.6) 주의: 레지스트리/카탈로그를 먼저 올릴 때는 :extensions 를 빈
# 리스트([])로 시작해도 된다(아직 확장 모듈이 컴파일 트리에 없을 수 있으므로 컴파일 에러 회피).
# 각 확장(EXT-1/EXT-2/애드온)을 통합할 때 해당 모듈을 리스트에 한 줄씩 추가한다.

import Config

# ── 확장 레지스트리: 명시 목록(= 카탈로그 노출 대상) ──────────────────────
#
# "등록(이 리스트 포함) ≠ 활성(각 확장의 enabled?)".
# 비활성 확장도 카탈로그에 '비활성' 배지로 노출되어야 하므로, 리스트에는 항상 전부 넣는다.
# 켜고 끄는 것은 각 확장의 enabled? (아래 게이트 블록)가 결정한다.
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension
  # ── 애드온 5개는 7.b 구현 통합 시 아래에 추가(이 기반 작업 범위 밖) ──
  # OpenMes.Addons.WoCsvExport.Extension,
  # OpenMes.Addons.DefectStats.Extension,
  # OpenMes.Addons.LotQrLabel.Extension,
  # OpenMes.Addons.EquipmentOee.Extension,
  # OpenMes.Addons.DailyProductionSummary.Extension
]

# ── 확장 게이트(기본값) ──────────────────────────────────────────────────
# 코어는 항상 동작한다. EXT-1/EXT-2 는 외부 인프라(TimescaleDB/MinIO) 의존이 있어 기본 off.
# 카탈로그에서는 "비활성(인프라 미설정)" 배지로 자연히 구분되어 보인다.

# EXT-1 설비 수집 — 기본 비활성(06 config.snippets.md 승계)
config :open_mes, OpenMes.Ingest,
  enabled: false,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: []

# EXT-2 멀티미디어 — 기본 비활성(07 CORE_PATCH.md 승계)
config :open_mes, OpenMes.Media,
  enabled: false,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink

# ── 애드온 게이트(애드온 통합 시 추가) ───────────────────────────────────
# 설계 §5 결정: 애드온은 읽기 전용 + 인프라 의존 없음 → 기본 on 가능(안전).
# config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
# config :open_mes, OpenMes.Addons.DefectStats, enabled: true
# config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
# config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
# config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true

# phx.new 가 생성하는 import_config "#{config_env()}.exs" 는 파일 끝에 유지한다.
# import_config "#{config_env()}.exs"
