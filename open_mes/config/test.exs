import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :open_mes, OpenMes.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "open_mes_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :open_mes, OpenMesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "a2o88Vt/2Vfmr68s0qNTVjRhm1Zv4bujZyR+5dpGM9mkf6tXeQhNqqHloB9yhpPG",
  server: false

# async 테스트의 LiveView/요청 프로세스가 테스트 소유자의 sandbox 커넥션을
# 공유하도록 endpoint 에 Phoenix.Ecto.SQL.Sandbox plug 를 켠다(ConnCase 가 conn
# 메타데이터를 주입).
config :open_mes, :sql_sandbox, true

# ── EXT-1 설비 수집 — 테스트에서 활성화 ─────────────────────────────────────
# 라우터의 /ingest scope 는 컴파일 타임 `OpenMes.Ingest.enabled?()` 로 등록되고,
# Broadway 파이프라인은 application.ex 가 enabled? 기준으로 기동한다. ingest 컨트롤러/
# 파이프라인 테스트(인증·202·dead-letter 적재)는 활성 상태를 전제로 하므로 여기서 켠다.
# sink 는 NoopSink(코어로 아무것도 흘리지 않음) — 적재는 파이프라인 Loader 가 직접 한다.
config :open_mes, OpenMes.Ingest,
  enabled: true,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: ["test-token"]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
