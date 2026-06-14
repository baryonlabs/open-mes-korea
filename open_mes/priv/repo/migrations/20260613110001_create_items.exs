defmodule OpenMes.Repo.Migrations.CreateItems do
  @moduledoc """
  품목(items) 테이블 생성 — 기준정보.

  docs/domain-model.md Item 정의 + 설계 §1.3(1).
  애드온 계약(daily_production_summary): item_code, name, item_type, unit, active.
  컬럼명 변경 금지(애드온 읽기 스키마와 1:1 일치).
  """
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 품목 코드(유일). 예: "ITM-0001"
      add :item_code, :string, null: false
      add :name, :string, null: false
      # 원자재(raw)/반제품(semi)/제품(product)
      add :item_type, :string, null: false
      # 단위. 예: EA, kg
      add :unit, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:items, [:item_code])
    create index(:items, [:item_type])
    create index(:items, [:active])

    # item_type 은 정의된 3종만 허용(changeset 우회 직접 SQL 최후 방어선).
    create constraint(:items, :items_item_type_check,
             check: "item_type IN ('raw','semi','product')"
           )
  end
end
