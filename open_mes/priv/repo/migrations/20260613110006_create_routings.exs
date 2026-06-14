defmodule OpenMes.Repo.Migrations.CreateRoutings do
  @moduledoc """
  라우팅(routings) 테이블 생성 — 기준정보.

  docs/domain-model.md Routing + 설계 §1.3(4).
  애드온 계약(equipment_oee): item_id, process_id, sequence, standard_cycle_time.
  컬럼명 변경 금지. 품목 내 순서(sequence) 유일.
  """
  use Ecto.Migration

  def change do
    create table(:routings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :item_id, references(:items, type: :binary_id, on_delete: :restrict), null: false

      add :process_id, references(:processes, type: :binary_id, on_delete: :restrict),
        null: false

      add :sequence, :integer, null: false
      # 표준 cycle time(초/개). 선택.
      add :standard_cycle_time, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create index(:routings, [:item_id])
    create unique_index(:routings, [:item_id, :sequence])

    create constraint(:routings, :routings_sequence_positive, check: "sequence > 0")
  end
end
