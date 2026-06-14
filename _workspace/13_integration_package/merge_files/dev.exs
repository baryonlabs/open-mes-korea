# config/dev.exs — 확장 추가분 병합 기준본 (개발 환경)
#
# phx.new 가 생성한 dev.exs 의 Repo(DB 접속)/Endpoint(watchers, code reloader) 설정은 그대로 두고,
# 아래 블록을 추가한다.
#
# 핵심: 개발 중에는 docker-compose 의 TimescaleDB/MinIO 가 떠 있으므로 EXT-1/EXT-2 를 켤 수 있다.

import Config

# ── DB (phx.new 가 만든 config :open_mes, OpenMes.Repo 블록을 아래 값으로 맞춘다) ──
# docker-compose.yml 의 timescale/timescaledb 컨테이너와 일치.
# (phx.new 기본 username/password 가 postgres/postgres 라면 그대로 두면 됨)
config :open_mes, OpenMes.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "open_mes_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ── EXT-1 설비 수집 — 개발에서 켜기(TimescaleDB 컨테이너 전제) ──────────────
# 디바이스 토큰은 개발용 더미. 끄려면 enabled: false.
config :open_mes, OpenMes.Ingest,
  enabled: true,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: ["dev-device-token"]

# ── EXT-2 멀티미디어 — 개발에서 켜기(MinIO 컨테이너 전제) ──────────────────
# watch_roots 는 로컬에서 감시할 디렉토리. 없으면 빈 리스트로 두어도 안전.
config :open_mes, OpenMes.Media,
  enabled: true,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink,
  bucket: "open-mes-media",
  watch_roots: []

# ── ex_aws (MinIO) — 개발 엔드포인트 ───────────────────────────────────────
config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000

# ── 애드온 — 개발에서 전부 켜서 카탈로그 "열기" 링크를 모두 확인 ───────────
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
