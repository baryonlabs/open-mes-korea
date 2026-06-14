defmodule OpenMes.Repo.Migrations.CreateAuditLogs do
  @moduledoc """
  감사 로그(audit_logs) 테이블 생성.

  모든 쓰기 작업(생성/변경/상태전이)의 이력을 append-only 로 적재한다.
  domain-model.md L105-115 의 AuditLog 엔티티에 대응.
  도메인 모델상의 `created_at` 은 Ecto 관례에 따라 `inserted_at` 으로 매핑한다.
  """
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 행위자 식별자. MVP 단계는 인증 미구현이므로 X-Actor-Id 헤더 문자열을 그대로 저장한다.
      add :actor_id, :string, null: false
      # 수행한 동작. 예: "work_order.create", "work_order.release"
      add :action, :string, null: false
      # 대상 리소스 종류. 예: "work_order"
      add :resource_type, :string, null: false
      # 대상 리소스 식별자(UUID)
      add :resource_id, :binary_id, null: false
      # 변경 전 스냅샷(jsonb). 생성 작업은 nil.
      add :before, :map
      # 변경 후 스냅샷(jsonb).
      add :after, :map

      # AuditLog 는 append-only 이므로 updated_at 은 두지 않는다. inserted_at 만 기록.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # 리소스 단위 이력 조회용
    create index(:audit_logs, [:resource_type, :resource_id])
    # 행위자별 추적용
    create index(:audit_logs, [:actor_id])
    # 동작 유형별 집계/조회용
    create index(:audit_logs, [:action])
  end
end
