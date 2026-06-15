# config/test.exs — 테스트 환경 확장 게이트 (설계 §4.2)
#
# 이 파일은 phx.new 가 생성한 test.exs 위에 **확장 테스트 게이트만 추가/병합**하는 기준이다.
# phx.new 가 만드는 Repo(test 풀)/Endpoint(server: false) 설정은 그대로 둔다.
#
# 라우터의 확장 scope 는 컴파일 타임에 `enabled?` 로 게이트되므로(router 패치 패턴),
# 해당 라우트를 테스트하려면 테스트 환경에서 enabled: true 여야 한다.

import Config

# EXT-1: /ingest 컨트롤러 테스트가 필요하면 활성화(06 승계).
config :open_mes, OpenMes.Ingest,
  enabled: true,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: ["test-token"]

# EXT-2: 자체 라우트 없음. NoopSink 로 부수효과 없이 테스트.
config :open_mes, OpenMes.Media,
  enabled: false,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink

# 카탈로그 테스트는 :extensions 리스트(config.exs)를 그대로 사용한다.
# 레지스트리 테스트는 Application.put_env 로 :extensions 를 임시 주입/복원하므로
# 여기서 별도 설정이 필요 없다(test/open_mes/extensions/registry_test.exs 참조).

# 애드온 통합 시: router scope 게이트를 위해 test 에서 enabled: true 보장(설계 §7.c).
# config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
# config :open_mes, OpenMes.Addons.DefectStats, enabled: true
# config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
# config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
# config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
