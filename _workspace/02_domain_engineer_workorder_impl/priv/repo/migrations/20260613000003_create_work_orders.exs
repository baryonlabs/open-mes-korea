defmodule OpenMes.Repo.Migrations.CreateWorkOrders do
  @moduledoc """
  작업지시(work_orders) 테이블 생성.

  domain-model.md 의 WorkOrder 엔티티 + 상태 머신(draft → released → in_progress
  → completed/cancelled)에 대응.

  item_id 주의:
    items 테이블이 아직 존재하지 않으므로 이번 마이그레이션에서는 FK(references) 없이
    컬럼만 생성한다. 기준정보(Item) 구현 후 별도 후속 마이그레이션에서 FK 제약을 추가한다.
  """
  use Ecto.Migration

  def change do
    create table(:work_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 작업지시번호. 예: "WO-20260613-0001". 앱+DB 이중으로 유일성 보장.
      add :work_order_no, :string, null: false
      # 생산 대상 품목 식별자. FK 는 items 테이블 구현 후 후속 마이그레이션에서 추가(위 주석 참조).
      add :item_id, :binary_id, null: false
      # 계획 수량. kg 등 비정수 단위 고려해 decimal 사용.
      add :planned_quantity, :decimal, null: false
      # 납기일(선택)
      add :due_date, :date
      # 상태 머신 값. 기본 draft.
      add :status, :string, null: false, default: "draft"

      # 각 상태 전이 시각(전이 시 해당 컬럼만 채워짐)
      add :released_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # 작업지시번호 유일성(DB 레벨 보장)
    create unique_index(:work_orders, [:work_order_no])
    # 상태별 현황 조회용
    create index(:work_orders, [:status])
    # 품목별 조회용
    create index(:work_orders, [:item_id])
    # 납기 정렬/조회용
    create index(:work_orders, [:due_date])

    # 상태값은 정의된 5종만 허용 — changeset 우회(직접 SQL)에 대한 최후 방어선.
    # 단, 전이 규칙 자체는 CHECK 로 표현 불가하므로 앱 레벨 state machine 이 1차 책임이다.
    create constraint(:work_orders, :work_orders_status_check,
             check: "status IN ('draft','released','in_progress','completed','cancelled')"
           )

    # 계획 수량은 0 보다 커야 함
    create constraint(:work_orders, :work_orders_planned_quantity_positive,
             check: "planned_quantity > 0"
           )
  end
end
