defmodule OpenMes.Addons.DefectStats.TestTables do
  @moduledoc """
  애드온 ② 집계 테스트용 테이블 헬퍼(테스트 전용).

  `production_results`, `defect_records` 는 코어 MVP(WorkOrder)에는 아직 마이그레이션이
  없다(설계 §2: 애드온은 기존 테이블을 읽기로 매핑). 통합 환경에서는 코어/후속 작업이
  이 테이블을 만든다. **이 헬퍼는 애드온 단위 테스트가 코어 없이도 자체적으로 돌도록**
  동일 스키마의 임시 테이블을 만든다(읽기 전용 집계 검증 목적). 운영 마이그레이션이 아니다.

  통합 후에는 코어/EXT 마이그레이션이 두 테이블을 제공하므로 이 헬퍼는 불필요해진다.
  """
  alias Ecto.Adapters.SQL

  @doc "테스트 시작 전 한 번 호출해 두 테이블을 생성한다(이미 있으면 무시)."
  def ensure!(repo \\ OpenMes.Repo) do
    SQL.query!(repo, """
    CREATE TABLE IF NOT EXISTS production_results (
      id uuid PRIMARY KEY,
      operation_id uuid,
      worker_id uuid,
      equipment_id uuid,
      good_quantity numeric,
      defect_quantity numeric,
      started_at timestamptz,
      ended_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    SQL.query!(repo, """
    CREATE TABLE IF NOT EXISTS defect_records (
      id uuid PRIMARY KEY,
      production_result_id uuid,
      defect_code text,
      quantity numeric,
      note text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    :ok
  end
end
