defmodule OpenMes.Repo.Migrations.EnableTimescaledb do
  @moduledoc """
  TimescaleDB 확장 활성화.

  설계 §2.4-(1). equipment_measurements 를 hypertable 로 전환하기 위한 전제다.
  운영 DB 에 TimescaleDB 가 설치된 이미지여야 한다(예: timescale/timescaledb:latest-pg16).
  설치가 안 되어 있으면 이 마이그레이션이 실패한다 — 그러나 코어는 영향받지 않는다
  (ingest 확장은 enabled:false 가 기본이며, 이 마이그레이션은 ingest 도입 시에만 실행).

  주의: 확장 제거(DROP EXTENSION)는 동일 DB 의 다른 hypertable 까지 파괴할 수 있어 위험하므로
  down 은 의도적으로 no-op 로 둔다(롤백으로 확장을 지우지 않는다).
  """
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS timescaledb;"
  end

  def down do
    # 확장 제거는 위험(다른 hypertable 영향) → 의도적 no-op.
    :ok
  end
end
