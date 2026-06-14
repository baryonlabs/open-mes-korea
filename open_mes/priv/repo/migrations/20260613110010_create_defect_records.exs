defmodule OpenMes.Repo.Migrations.CreateDefectRecords do
  @moduledoc """
  불량 기록(defect_records) 테이블 생성 — append-only.

  docs/domain-model.md DefectRecord + 설계 §1.3(9).
  애드온 계약(defect_stats): production_result_id, defect_code, quantity, note.
  """
  use Ecto.Migration

  def change do
    create table(:defect_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :production_result_id,
          references(:production_results, type: :binary_id, on_delete: :restrict),
          null: false

      add :defect_code, :string, null: false
      add :quantity, :decimal, null: false
      add :note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:defect_records, [:production_result_id])
    create index(:defect_records, [:defect_code])

    create constraint(:defect_records, :defect_records_quantity_positive, check: "quantity > 0")
  end
end
