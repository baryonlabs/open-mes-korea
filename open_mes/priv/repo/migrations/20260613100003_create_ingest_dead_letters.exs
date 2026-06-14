defmodule OpenMes.Repo.Migrations.CreateIngestDeadLetters do
  @moduledoc """
  수집 검증 실패(오염 데이터) 격리 테이블(ingest_dead_letters). 설계 §5.2.

  성격: 저빈도 일반 PostgreSQL 테이블(hypertable 아님). append-only.
    검증 실패 메시지는 재시도해도 영원히 실패하므로 즉시 이곳에 격리한다(무한 재시도 루프 차단).

  이것은 AuditLog 가 아니다. 도메인 변경 이력이 아니라 수집 오류 격리소이며
  코어 audit_logs 와 무관하다(설계 §5.2). 저빈도이므로 UUID PK 무방.
  """
  use Ecto.Migration

  def change do
    create table(:ingest_dead_letters, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 원본 메시지 그대로(재처리/분석용)
      add :raw_payload, :map, null: false
      # 실패 사유. 예: "missing:equipment_id", "skew_exceeded"
      add :reason, :string, null: false
      # 디바이스 토큰 라벨(어느 출처의 오염인지 추적용). 없을 수 있음.
      add :source, :string

      # 격리 시각만 기록(append-only — updated_at 없음).
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # 사유별 집계/분석용
    create index(:ingest_dead_letters, [:reason])
    # 시간순 조회용
    create index(:ingest_dead_letters, [:inserted_at])
  end

  # append-only: 운영자가 분석 후 수동 정리(또는 후속 retention). DELETE/UPDATE 함수 미작성.
end
