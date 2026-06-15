defmodule OpenMes.Repo.Migrations.CreateOutboxEvents do
  @moduledoc """
  이벤트 아웃박스(outbox_events) 테이블 생성.

  상태 변경 시 도메인 이벤트를 동일 DB 트랜잭션 안에서 적재한다(PostgreSQL outbox 패턴).
  system-architecture.md L42-57 기준.

  MVP 범위 주의: 적재된 이벤트를 외부로 발행하는 발행 워커는 이번 범위 밖이다.
  이벤트가 상태 변경과 같은 트랜잭션으로 안전하게 적재되는 것까지만 보장한다.
  """
  use Ecto.Migration

  def change do
    create table(:outbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 이벤트 종류. 예: "work_order.released"
      add :event_type, :string, null: false
      # 집계(애그리거트) 종류. 예: "work_order"
      add :aggregate_type, :string, null: false
      # 이벤트 대상 식별자(UUID)
      add :aggregate_id, :binary_id, null: false
      # 이벤트 본문(jsonb)
      add :payload, :map, null: false
      # 발행 상태. "pending"(미발행) → "published"(발행완료). MVP 는 적재만 하므로 항상 pending.
      add :status, :string, null: false, default: "pending"
      # 이벤트 발생 시각
      add :occurred_at, :utc_datetime_usec, null: false
      # 발행 시각(후속 발행 워커가 채움)
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # 미발행 이벤트 폴링용
    create index(:outbox_events, [:status])
    # 집계 단위 이벤트 조회용
    create index(:outbox_events, [:aggregate_type, :aggregate_id])

    # status 는 정의된 두 값만 허용 — 잘못된 직접 INSERT 에 대한 최후 방어선
    create constraint(:outbox_events, :outbox_events_status_check,
             check: "status IN ('pending','published')"
           )
  end
end
