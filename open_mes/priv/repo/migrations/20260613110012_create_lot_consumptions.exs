defmodule OpenMes.Repo.Migrations.CreateLotConsumptions do
  @moduledoc """
  LOT 투입 기록(lot_consumptions) 테이블 생성 — append-only.

  docs/domain-model.md LotConsumption + 설계 §1.3(11).
  자재 소비는 이 테이블 경유만(암묵 소비 금지, CLAUDE.md L73).
  genealogy: 제품LOT.source_operation_id → operation → lot_consumptions → input_lot.
  """
  use Ecto.Migration

  def change do
    create table(:lot_consumptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operation_id, references(:operations, type: :binary_id, on_delete: :restrict),
        null: false

      add :input_lot_id, references(:material_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :quantity, :decimal, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:lot_consumptions, [:operation_id])
    create index(:lot_consumptions, [:input_lot_id])

    create constraint(:lot_consumptions, :lot_consumptions_quantity_positive,
             check: "quantity > 0"
           )
  end
end
