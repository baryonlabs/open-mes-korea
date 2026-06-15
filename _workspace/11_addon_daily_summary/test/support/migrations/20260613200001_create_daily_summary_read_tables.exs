defmodule OpenMes.Repo.Migrations.CreateDailySummaryReadTables do
  @moduledoc """
  애드온 ⑤ 테스트 지원용 마이그레이션.

  ## 성격(중요)

  이 마이그레이션은 **애드온 자신의 테이블이 아니다.** 애드온 ⑤ 는 새 테이블을 0개 만든다.
  여기서 만드는 `items` / `operations` / `production_results` 는 **코어 기준정보·생산실적
  테이블**로, 코어/EXT 가 정식 구현하면 그 마이그레이션이 이 테이블을 소유한다.

  MVP 시점에는 코어가 아직 이 테이블들을 마이그레이션으로 만들지 않았으므로, 애드온 ⑤ 의
  집계 쿼리(읽기 전용)를 **테스트에서 실제로 실행**하려면 테이블이 존재해야 한다.
  그래서 이 파일을 **테스트 지원**(test/support/migrations)으로 제공한다.

  통합(설계 §4) 시:
    - 코어/기준정보가 `items`/`operations`/`production_results` 를 정식 마이그레이션으로
      만들면 **이 테스트 지원 마이그레이션은 삭제**한다(중복 생성 충돌 방지).
    - 그 전까지는 애드온 테스트가 독립적으로 통과하도록 이 파일을 priv 마이그레이션 경로에
      포함시키거나(테스트 전용 config), 통합 환경에서는 코어 테이블을 그대로 사용한다.

  필드는 `docs/domain-model.md` 의 Item/Operation/ProductionResult 정의를 따른다.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_code, :string, null: false
      add :name, :string, null: false
      add :item_type, :string
      add :unit, :string
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :work_order_id, :binary_id, null: false
      add :process_id, :binary_id
      add :sequence, :integer
      add :status, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:production_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :binary_id, null: false
      add :worker_id, :binary_id
      add :equipment_id, :binary_id
      add :good_quantity, :decimal
      add :defect_quantity, :decimal
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # 집계 쿼리 성능: 선택일 ended_at 범위 필터 + operation 조인.
    create_if_not_exists index(:production_results, [:ended_at])
    create_if_not_exists index(:production_results, [:operation_id])
    create_if_not_exists index(:operations, [:work_order_id])
  end
end
