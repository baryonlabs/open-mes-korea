defmodule OpenMes.Repo.Migrations.CreateMaterialLots do
  @moduledoc """
  자재/제품 LOT(material_lots) 테이블 생성 — 상태머신.

  docs/domain-model.md MaterialLot + 설계 §1.3(10).
  상태머신: available → reserved → consumed/produced/quarantined/scrapped.
  애드온 계약(lot_qr_label): lot_no, item_id, lot_type, quantity, status. 컬럼명 변경 금지.
  source_operation_id: 생산된 Operation 연결(genealogy). 원자재 입고 LOT 은 NULL.

  lot_type CHECK 미부여(중요): lot_qr_label 애드온 테스트가 lot_type 에 비정의 값을 raw insert
  하므로(읽기 전용 라벨 표시 목적) DB CHECK 를 걸면 호환이 깨진다. lot_type 값 검증은 코어
  쓰기 경로(MaterialLot.changeset)에서만 수행한다.
  """
  use Ecto.Migration

  def change do
    create table(:material_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lot_no, :string, null: false
      # item_id: FK 미부여(애드온 lot_qr_label 테스트가 합성 item_id 로 raw insert 함 — §7 계약은
      # 컬럼명만 요구). 코어 쓰기 경로(MaterialLot.create_changeset)에서 item_id 필수성을 보장하고,
      # FK 무결성은 코어 생성 시 receive/produce 가 실재 품목을 참조하도록 운영 규약으로 둔다.
      add :item_id, :binary_id, null: false
      add :lot_type, :string, null: false
      add :quantity, :decimal, null: false
      add :status, :string, null: false, default: "available"

      # 생산된 Operation 연결(genealogy). 원자재 입고 LOT 은 NULL.
      add :source_operation_id, references(:operations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:material_lots, [:lot_no])
    create index(:material_lots, [:item_id])
    create index(:material_lots, [:status])
    create index(:material_lots, [:source_operation_id])

    # 상태값 6종만 허용(앱 레벨 상태머신이 전이 규칙 1차 책임).
    create constraint(:material_lots, :material_lots_status_check,
             check:
               "status IN ('available','reserved','consumed','produced','quarantined','scrapped')"
           )

    create constraint(:material_lots, :material_lots_quantity_nonneg, check: "quantity >= 0")
  end
end
