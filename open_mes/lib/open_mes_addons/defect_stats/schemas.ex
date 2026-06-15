defmodule OpenMes.Addons.DefectStats.Schemas do
  @moduledoc """
  애드온 ② 의 **읽기 전용** Ecto 스키마.

  ## 왜 애드온이 스키마를 정의하나

  코어(`OpenMes.Production`)는 MVP 시점에 `WorkOrder` 만 스키마로 노출하고
  `DefectRecord`/`ProductionResult` 컨텍스트/조회 함수는 아직 없다. 설계 §2 결정에 따라
  **코어를 건드리지 않고**(비침투) 애드온에서 기존 테이블(`defect_records`, `production_results`)을
  읽기 전용으로 매핑한다. 코어에 조회 함수를 추가하지 않는다(코어 침투 회피가 우선).

  ## 읽기 전용 보증

  여기 정의된 스키마는 **changeset 이 없다**. 쓰기 경로를 의도적으로 제공하지 않으므로
  이 모듈을 통해서는 INSERT/UPDATE/DELETE 가 불가능하다(집계 SELECT 전용).
  코어가 `defect_records`/`production_results` 테이블을 마이그레이션으로 만든다는 전제이며,
  필드는 docs/domain-model.md 의 정의를 따른다. 코어가 정식 스키마를 노출하면 이 모듈은
  그 스키마 alias 로 교체할 수 있다(인터페이스 동일).
  """

  defmodule ProductionResult do
    @moduledoc "공정 실적(읽기 전용 매핑). docs/domain-model.md `ProductionResult`."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "production_results" do
      field :operation_id, :binary_id
      field :worker_id, :binary_id
      field :equipment_id, :binary_id
      field :good_quantity, :decimal
      field :defect_quantity, :decimal
      field :started_at, :utc_datetime_usec
      field :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule DefectRecord do
    @moduledoc "불량 기록(읽기 전용 매핑). docs/domain-model.md `DefectRecord`."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "defect_records" do
      field :production_result_id, :binary_id
      field :defect_code, :string
      field :quantity, :decimal
      field :note, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
