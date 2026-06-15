# 테스트 지원 마이그레이션 적용.
#
# test/support/migrations/ 의 마이그레이션은 코어가 아직 정식으로 만들지 않은 테이블
# (items/operations/production_results/material_lots/defect_records)을 애드온 테스트가
# 코어 없이도 실행할 수 있도록 보강한다. 모두 `create_if_not_exists` 라 통합 후 코어
# 마이그레이션과 충돌하지 않는다. (설계 §4 — 통합 시 삭제 대상)
support_migrations = Path.expand("support/migrations", __DIR__)

if File.dir?(support_migrations) do
  Ecto.Migrator.run(OpenMes.Repo, support_migrations, :up, all: true, log_migrations_sql: false)
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(OpenMes.Repo, :manual)
