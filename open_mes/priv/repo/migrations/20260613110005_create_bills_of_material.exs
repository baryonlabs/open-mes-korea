defmodule OpenMes.Repo.Migrations.CreateBillsOfMaterial do
  @moduledoc """
  BOM(bills_of_material) 테이블 생성 — 기준정보.

  docs/domain-model.md BillOfMaterial + 설계 §1.3(2).
  parent/child 모두 items FK. 동일 부모-자식 중복 방지(unique).
  """
  use Ecto.Migration

  def change do
    create table(:bills_of_material, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :parent_item_id, references(:items, type: :binary_id, on_delete: :restrict),
        null: false

      add :child_item_id, references(:items, type: :binary_id, on_delete: :restrict), null: false

      add :quantity, :decimal, null: false
      add :loss_rate, :decimal, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:bills_of_material, [:parent_item_id])
    create unique_index(:bills_of_material, [:parent_item_id, :child_item_id])

    # 수량은 0 보다 커야 하고, 손실률은 0..1 범위.
    create constraint(:bills_of_material, :bills_of_material_quantity_positive,
             check: "quantity > 0"
           )

    create constraint(:bills_of_material, :bills_of_material_loss_rate_range,
             check: "loss_rate >= 0 AND loss_rate <= 1"
           )
  end
end
