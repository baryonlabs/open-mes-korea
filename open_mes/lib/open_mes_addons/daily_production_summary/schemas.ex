defmodule OpenMes.Addons.DailyProductionSummary.Schemas do
  @moduledoc """
  애드온 ⑤ 의 **읽기 전용** Ecto 스키마.

  ## 왜 애드온이 스키마를 정의하나

  코어(`OpenMes.Production`)는 MVP 시점에 `WorkOrder` 만 스키마/공개 조회 함수로 노출하고
  `ProductionResult`/`Item` 컨텍스트는 아직 없다. 설계 §2 결정에 따라 **코어를 건드리지 않고**
  (비침투) 기존 테이블(`production_results`, `items`)을 애드온에서 읽기 전용으로 매핑한다.
  코어에 조회 함수를 추가하지 않는다(코어 침투 회피가 우선).

  (작업지시는 코어 공개 함수 `OpenMes.Production.list_work_orders/1` 로 읽으므로 WorkOrder
  스키마는 여기서 다시 정의하지 않는다.)

  ## 읽기 전용 보증(필수, 설계 §0-B-6 / §2)

  여기 정의된 스키마는 **changeset 이 없다.** 쓰기 경로를 의도적으로 제공하지 않으므로
  이 모듈을 통해서는 INSERT/UPDATE/DELETE 가 불가능하다(집계 SELECT 전용).
  필드는 `docs/domain-model.md` 의 정의를 따른다. 코어가 정식 스키마를 노출하면 이 모듈은
  그 스키마 alias 로 교체할 수 있다(인터페이스 동일).
  """

  defmodule ProductionResult do
    @moduledoc "공정 실적(읽기 전용 매핑). docs/domain-model.md `ProductionResult`."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    # 읽기 전용: changeset 이 없으므로 Repo 쓰기 경로의 입력이 될 수 없다.
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
    작업지시 공정 실행 단위(읽기 전용 매핑). docs/domain-model.md `Operation`.

    품목별 집계를 위해 `ProductionResult → Operation → WorkOrder → Item` 조인 체인의
    중간 다리로만 읽는다(operation_id → work_order_id).
    """
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    # 읽기 전용: changeset 이 없으므로 Repo 쓰기 경로의 입력이 될 수 없다.
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

  defmodule Item do
    @moduledoc "품목(읽기 전용 매핑). docs/domain-model.md `Item`."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    # 읽기 전용: changeset 이 없으므로 Repo 쓰기 경로의 입력이 될 수 없다.
    schema "items" do
      field :item_code, :string
      field :name, :string
      field :item_type, :string
      field :unit, :string
      field :active, :boolean

      timestamps(type: :utc_datetime_usec)
    end
  end
end
