defmodule OpenMes.Repo.Migrations.CreateOperations do
  @moduledoc """
  공정 실행 단위(operations) 테이블 생성 — 생산 실행.

  docs/domain-model.md Operation + 설계 §1.3(7).
  상태머신: pending → ready → running → paused → completed/skipped.
  애드온 계약(daily_production_summary, equipment_oee):
    work_order_id, process_id, sequence, status, started_at, completed_at.
  주의: operations.completed_at (production_results.ended_at 와 명칭 구분).
  """
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :work_order_id, references(:work_orders, type: :binary_id, on_delete: :restrict),
        null: false

      # process_id: nullable + FK 미부여.
      # 애드온 단위 테스트(daily_production_summary)가 process 조인 없이 operation 을 raw insert
      # 하므로 호환을 위해 DB NOT NULL/FK 를 강제하지 않는다. 코어 쓰기 경로(Operation.create_changeset)
      # 에서 process_id 필수성을 보장한다. 애드온 §7 계약은 컬럼명만 요구한다.
      add :process_id, :binary_id

      add :sequence, :integer, null: false
      add :status, :string, null: false, default: "pending"
      # running 최초 진입 시 started_at, completed 시 completed_at.
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:operations, [:work_order_id])
    create index(:operations, [:status])
    create unique_index(:operations, [:work_order_id, :sequence])

    # 상태값 6종만 허용(앱 레벨 상태머신이 전이 규칙 1차 책임).
    create constraint(:operations, :operations_status_check,
             check:
               "status IN ('pending','ready','running','paused','completed','skipped')"
           )
  end
end
