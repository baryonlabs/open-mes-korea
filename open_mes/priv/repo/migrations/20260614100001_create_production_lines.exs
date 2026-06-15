defmodule OpenMes.Repo.Migrations.CreateProductionLines do
  @moduledoc """
  생산라인 구성(production_lines + production_line_steps) 테이블 생성 — 설계 22번 §1.

  라인 모니터의 정규식 하드코딩(`~r/^P\\d{2}$/`)·설비 규약(`"EQ-"<>code`)을
  설정 데이터(FK)로 승격한다. ProductionLineStep 은 Routing 과 무관(모니터 표시 구성).
  """
  use Ecto.Migration

  def change do
    create table(:production_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :line_code, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:production_lines, [:line_code])

    create table(:production_line_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :line_id, references(:production_lines, type: :binary_id, on_delete: :restrict),
        null: false

      add :process_id, references(:processes, type: :binary_id, on_delete: :restrict),
        null: false

      # 대표 설비(없으면 모니터 unknown). nullable FK.
      add :equipment_id, references(:equipment, type: :binary_id, on_delete: :restrict)

      add :sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:production_line_steps, [:line_id])
    create unique_index(:production_line_steps, [:line_id, :sequence])

    create constraint(:production_line_steps, :production_line_steps_sequence_positive,
             check: "sequence > 0"
           )
  end
end
