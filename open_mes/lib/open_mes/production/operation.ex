defmodule OpenMes.Production.Operation do
  @moduledoc """
  공정 실행 단위(Operation) Ecto 스키마 + changeset.

  WorkOrder 와 동일한 changeset 분리 원칙:
    - `create_changeset/2` : 생성 전용. status 는 항상 "pending" 으로 강제.
    - `transition_changeset/2` : 상태 전이 전용. 허용 전이만 통과, *_at 타임스탬프 자동 기록.

  상태머신은 `OperationStateMachine` 에 위임. 일반 update changeset 은 제공하지 않는다
  (Operation 은 status 외 필드 수정 유스케이스가 없고, status 는 전이 경로로만 변경).

  타임스탬프 기록:
    - running 최초 진입 시 started_at(이미 있으면 보존)
    - completed 시 completed_at
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenMes.Production.OperationStateMachine

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "operations" do
    field :work_order_id, :binary_id
    field :process_id, :binary_id
    field :sequence, :integer
    field :status, :string, default: "pending"

    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @statuses OperationStateMachine.statuses()

  @doc """
  공정 생성용 changeset. status 는 캐스트 제외하고 항상 "pending" 으로 강제한다.
  """
  def create_changeset(operation \\ %__MODULE__{}, attrs) do
    operation
    |> cast(attrs, [:work_order_id, :process_id, :sequence])
    |> validate_required([:work_order_id, :process_id, :sequence], message: "필수 항목입니다")
    |> validate_number(:sequence, greater_than: 0, message: "순서는 0 보다 커야 합니다")
    |> put_change(:status, "pending")
    |> foreign_key_constraint(:work_order_id, message: "존재하지 않는 작업지시입니다")
    |> foreign_key_constraint(:process_id, message: "존재하지 않는 공정입니다")
    |> unique_constraint([:work_order_id, :sequence],
      name: :operations_work_order_id_sequence_index,
      message: "이미 등록된 작업지시-순서 조합입니다"
    )
  end

  @doc """
  상태 전이 전용 changeset. 허용 전이표 검증 + 멱등(no-op) 전이 거부 + 타임스탬프 기록.
  (WorkOrder.transition_changeset 패턴 그대로.)
  """
  def transition_changeset(%__MODULE__{status: from} = operation, to) do
    base =
      operation
      |> cast(%{status: to}, [:status])
      |> validate_required([:status], message: "필수 항목입니다")
      |> validate_inclusion(:status, @statuses, message: "허용되지 않은 상태값입니다")

    cond do
      from == to ->
        add_error(base, :status, "이미 #{to} 상태입니다 (동일 상태로의 전이는 허용되지 않습니다)")

      true ->
        base
        |> validate_change(:status, fn :status, new_status ->
          if OperationStateMachine.can_transition?(from, new_status) do
            []
          else
            [status: "허용되지 않은 상태 전이입니다: #{from} → #{new_status}"]
          end
        end)
        |> put_transition_timestamp(operation, to)
    end
  end

  # running 최초 진입 시 started_at(기존 값 보존), completed 시 completed_at.
  defp put_transition_timestamp(changeset, %__MODULE__{started_at: started_at}, "running") do
    if is_nil(started_at),
      do: put_change(changeset, :started_at, DateTime.utc_now()),
      else: changeset
  end

  defp put_transition_timestamp(changeset, _operation, "completed"),
    do: put_change(changeset, :completed_at, DateTime.utc_now())

  defp put_transition_timestamp(changeset, _operation, _to), do: changeset
end
