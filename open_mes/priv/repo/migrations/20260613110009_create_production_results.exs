defmodule OpenMes.Repo.Migrations.CreateProductionResults do
  @moduledoc """
  공정 실적(production_results) 테이블 생성 — append-only.

  docs/domain-model.md ProductionResult + 설계 §1.3(8).
  애드온 계약(daily_production_summary, defect_stats, equipment_oee — 가장 중요):
    operation_id, worker_id, equipment_id, good_quantity, defect_quantity, started_at, ended_at.
  주의: production_results.ended_at (operations.completed_at 와 명칭 구분).

  operation_id nullable 사유(중요): 애드온 단위 테스트(defect_stats)가 operation 조인 없이
  실적만 raw insert 한다. 애드온 계약 호환을 위해 DB NOT NULL 을 강제하지 않고,
  코어 쓰기 경로의 필수성은 ProductionResult.changeset 에서 보장한다.
  """
  use Ecto.Migration

  def change do
    create table(:production_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # nullable + FK: 애드온 테스트(operation 미조인 raw insert) 호환. 코어 쓰기는 changeset 필수.
      add :operation_id, references(:operations, type: :binary_id, on_delete: :restrict)
      add :worker_id, references(:workers, type: :binary_id, on_delete: :nilify_all)
      add :equipment_id, references(:equipment, type: :binary_id, on_delete: :nilify_all)

      add :good_quantity, :decimal, null: false, default: 0
      add :defect_quantity, :decimal, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:production_results, [:operation_id])
    create index(:production_results, [:equipment_id])
    create index(:production_results, [:ended_at])

    create constraint(:production_results, :production_results_good_quantity_nonneg,
             check: "good_quantity >= 0"
           )

    create constraint(:production_results, :production_results_defect_quantity_nonneg,
             check: "defect_quantity >= 0"
           )
  end
end
