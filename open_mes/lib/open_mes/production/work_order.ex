defmodule OpenMes.Production.WorkOrder do
  @moduledoc """
  작업지시(WorkOrder) Ecto 스키마 + changeset.

  책임:
    - DB 매핑(필드/타입)과 필드 단위 검증.
    - 상태 전이 유효성 검증은 `WorkOrderStateMachine` 에 위임한다.

  changeset 분리 원칙(중요):
    - `create_changeset/2` : 생성 전용. status 는 캐스트 대상에서 제외하고 항상 "draft" 로 강제.
    - `update_changeset/2` : 필드 수정 전용. draft 상태에서만 허용. status 는 변경 불가.
    - `transition_changeset/2` : 상태 전이 전용. 허용된 전이만 통과시키고 *_at 타임스탬프 자동 기록.

  이렇게 분리하여 일반 수정 경로로는 status 를 절대 바꿀 수 없게 한다(전이는 전용 경로로만).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenMes.Production.WorkOrderStateMachine

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "work_orders" do
    field :work_order_no, :string
    # item_id: items 테이블 FK 는 후속 추가(마이그레이션 주석 참조). 현재는 단순 binary_id 컬럼.
    field :item_id, :binary_id
    field :planned_quantity, :decimal
    field :due_date, :date
    field :status, :string, default: "draft"

    field :released_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @statuses WorkOrderStateMachine.statuses()

  # 전이 시 기록할 *_at 컬럼 매핑
  @timestamp_field %{
    "released" => :released_at,
    "in_progress" => :started_at,
    "completed" => :completed_at,
    "cancelled" => :cancelled_at
  }

  @doc """
  작업지시 생성용 changeset.

  status 는 캐스트 대상에서 제외하고 항상 "draft" 로 강제한다.
  work_order_no 는 MVP 단계에서 클라이언트 필수 입력이다(자동 채번은 후속).
  """
  def create_changeset(work_order \\ %__MODULE__{}, attrs) do
    work_order
    |> cast(attrs, [:work_order_no, :item_id, :planned_quantity, :due_date])
    |> validate_required([:work_order_no, :item_id, :planned_quantity],
      message: "필수 항목입니다"
    )
    |> validate_number(:planned_quantity,
      greater_than: 0,
      message: "계획 수량은 0 보다 커야 합니다"
    )
    # 생성 시 상태는 항상 draft 로 강제(클라이언트가 status 를 보내도 무시)
    |> put_change(:status, "draft")
    |> unique_constraint(:work_order_no,
      name: :work_orders_work_order_no_index,
      message: "이미 존재하는 작업지시번호입니다"
    )
  end

  @doc """
  작업지시 필드 수정용 changeset.

  draft 상태에서만 planned_quantity, due_date 수정을 허용한다.
  status 는 캐스트 대상에서 제외(전이는 transition_changeset 전용 경로로만).
  draft 외 상태에서 호출되면 changeset 에러를 추가한다.
  """
  def update_changeset(%__MODULE__{status: status} = work_order, attrs) do
    changeset =
      work_order
      |> cast(attrs, [:planned_quantity, :due_date])
      |> validate_number(:planned_quantity,
        greater_than: 0,
        message: "계획 수량은 0 보다 커야 합니다"
      )

    if status == "draft" do
      changeset
    else
      add_error(changeset, :status, "draft 상태에서만 수정할 수 있습니다 (현재: #{status})")
    end
  end

  @doc """
  상태 전이 전용 changeset.

  현재 상태(`from`)에서 목표 상태(`to`)로의 전이가 허용 전이표에 있는지 검증하고,
  통과 시 해당 *_at 타임스탬프를 현재 시각으로 기록한다.
  허용되지 않은 전이는 :status 에러로 매핑되어 컨트롤러에서 422 로 흐른다.

  멱등(no-op) 전이 차단(중요):
    `to == from` 인 경우(예: 이미 released 인 WO 에 release 재호출) cast 가
    "변경 없음"으로 판단하여 Ecto `validate_change` 콜백이 호출되지 않는다.
    이 경로로 전이 검증이 스킵되면 종료 상태(completed/cancelled) 불변식이
    멱등 호출로 우회되고, 타임스탬프가 덮어써지며, 불필요한 AuditLog 가 쌓인다.
    이를 막기 위해 함수 진입부에서 `from == to` 를 무조건 평가하여 명시적으로 거부한다.
    (전이표에 자기 자신으로의 전이는 존재하지 않으므로 동일 상태 전이는 항상 불허다.)
  """
  def transition_changeset(%__MODULE__{status: from} = work_order, to) do
    base =
      work_order
      |> cast(%{status: to}, [:status])
      |> validate_required([:status], message: "필수 항목입니다")
      |> validate_inclusion(:status, @statuses, message: "허용되지 않은 상태값입니다")

    cond do
      # 동일 상태로의 전이(멱등 호출)는 changes 가 비어 validate_change 가 스킵되므로
      # 여기서 무조건 거부한다. 종료 상태 재호출(completed→completed 등)도 이 분기로 막힌다.
      from == to ->
        add_error(base, :status, "이미 #{to} 상태입니다 (동일 상태로의 전이는 허용되지 않습니다)")

      true ->
        base
        |> validate_change(:status, fn :status, new_status ->
          if WorkOrderStateMachine.can_transition?(from, new_status) do
            []
          else
            [status: "허용되지 않은 상태 전이입니다: #{from} → #{new_status}"]
          end
        end)
        |> put_transition_timestamp(to)
    end
  end

  # 전이 대상 상태에 대응하는 *_at 컬럼에 현재 시각을 기록한다.
  # (전이 검증을 통과한 경우에만 유효하지만, 검증 실패 시에는 어차피 트랜잭션이 롤백된다.)
  defp put_transition_timestamp(changeset, to) do
    case Map.get(@timestamp_field, to) do
      nil -> changeset
      field -> put_change(changeset, field, DateTime.utc_now())
    end
  end
end
