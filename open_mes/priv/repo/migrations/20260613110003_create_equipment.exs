defmodule OpenMes.Repo.Migrations.CreateEquipment do
  @moduledoc """
  설비(equipment) 테이블 생성 — 기준정보(신설).

  설계 §1.3(5) / §8 최소안(code/name/active). ProductionResult.equipment_id 가 참조.
  테이블명은 불가산 단수 `equipment`.
  """
  use Ecto.Migration

  def change do
    create table(:equipment, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :equipment_code, :string, null: false
      add :name, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:equipment, [:equipment_code])
    create index(:equipment, [:active])
  end
end
