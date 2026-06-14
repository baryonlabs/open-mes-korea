defmodule OpenMes.Addons.EquipmentOee.ReadModels do
  @moduledoc """
  애드온 ④ — 코어 테이블의 **읽기 전용 Ecto 투영(projection) 스키마**.

  설계 §2 결정: "애드온이 코어 스키마 모듈을 alias 해 **읽기 쿼리**에 사용하는 것은 허용
  (읽기는 침투가 아님). 쓰기/스키마 변경만 금지."

  ## 왜 애드온 안에 스키마를 두는가
  코어 `OpenMes.Production` 컨텍스트에는 현재 WorkOrder 만 구현되어 있고
  `ProductionResult`/`Operation`/`Routing` 스키마 모듈은 아직 없다(MVP 미구현).
  코어를 건드리지 않기 위해(비침투), 애드온은 docs/domain-model.md 가 정의한 테이블에
  대응하는 **얇은 읽기 전용 스키마**를 자기 네임스페이스에 둔다.

    - changeset/insert/update/delete 를 **정의하지 않는다** → 쓰기 불가(읽기 전용 강제).
    - 코어가 나중에 정식 스키마를 구현하면, 이 투영을 그쪽 alias 로 교체할 수 있다(후속).
    - 새 테이블을 만들지 않는다 — 기존(또는 예정) 코어 테이블에 매핑만 한다.

  PK/FK 는 코어 컨벤션(`binary_id`)을 따른다.
  """

  defmodule ProductionResult do
    @moduledoc """
    공정 실적(production_results) 읽기 투영. docs/domain-model.md ProductionResult.

    OEE 입력: `equipment_id`(설비 그룹화), `good_quantity`/`defect_quantity`(품질),
    `started_at`/`ended_at`(실가동시간). 결측(nil)은 호출부에서 안전 처리한다.
    """
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

  defmodule Operation do
    @moduledoc """
    공정 실행 단위(operations) 읽기 투영. docs/domain-model.md Operation.

    OEE 에서는 ProductionResult → Operation(work_order_id, process_id) → Routing
    연결 고리로만 쓰인다(표준 cycle time 조인용).
    """
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "operations" do
      field :work_order_id, :binary_id
      field :process_id, :binary_id
      field :sequence, :integer
      field :status, :string
      field :started_at, :utc_datetime_usec
      field :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Routing do
    @moduledoc """
    품목별 공정 순서(routings) 읽기 투영. docs/domain-model.md Routing.

    OEE 성능 계산의 `standard_cycle_time`(초/개) 출처. 결측 시 성능은 nil.
    """
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "routings" do
      field :item_id, :binary_id
      field :process_id, :binary_id
      field :sequence, :integer
      # 표준 cycle time. 단위는 초(초/개)로 가정한다(docs 미명시 — OEE 근사 가정).
      field :standard_cycle_time, :decimal

      timestamps(type: :utc_datetime_usec)
    end
  end
end
