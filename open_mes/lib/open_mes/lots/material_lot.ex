defmodule OpenMes.Lots.MaterialLot do
  @moduledoc """
  자재/제품 LOT(MaterialLot) Ecto 스키마 + changeset.

  WorkOrder 와 동일한 changeset 분리:
    - `create_changeset/2` : 생성 전용. 초기 status 는 available(원자재) 또는 produced(생산)만 허용.
    - `transition_changeset/2` : 상태 전이 전용(허용 전이만, 멱등 거부).

  상태머신은 `MaterialLotStateMachine` 에 위임.
  source_operation_id: 생산 LOT 이 어떤 Operation 에서 나왔는지(genealogy). 원자재는 NULL.
  애드온 계약(lot_qr_label): lot_no, item_id, lot_type, quantity, status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenMes.Lots.MaterialLotStateMachine

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses MaterialLotStateMachine.statuses()
  # 생성 시 진입 가능한 초기 상태만 허용(원자재 입고=available, 생산=produced).
  @initial_statuses ~w(available produced)
  @lot_types ~w(raw semi product)

  schema "material_lots" do
    field :lot_no, :string
    field :item_id, :binary_id
    field :lot_type, :string
    field :quantity, :decimal
    field :status, :string, default: "available"
    field :source_operation_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "정의된 LOT 유형 목록(raw/semi/product)."
  def lot_types, do: @lot_types

  @doc """
  LOT 생성용 changeset. 초기 status 는 available/produced 만 허용한다.
  source_operation_id 는 생산 LOT(produced)에서 genealogy 연결용으로 설정한다.
  """
  def create_changeset(lot \\ %__MODULE__{}, attrs) do
    lot
    |> cast(attrs, [:lot_no, :item_id, :lot_type, :quantity, :status, :source_operation_id])
    |> validate_required([:lot_no, :item_id, :lot_type, :quantity], message: "필수 항목입니다")
    |> validate_inclusion(:lot_type, @lot_types, message: "허용되지 않은 LOT 유형입니다")
    |> put_default_status()
    |> validate_inclusion(:status, @initial_statuses,
      message: "생성 시 초기 상태는 available 또는 produced 만 가능합니다"
    )
    |> validate_number(:quantity,
      greater_than_or_equal_to: 0,
      message: "수량은 0 이상이어야 합니다"
    )
    |> foreign_key_constraint(:item_id, message: "존재하지 않는 품목입니다")
    |> foreign_key_constraint(:source_operation_id, message: "존재하지 않는 공정입니다")
    |> unique_constraint(:lot_no,
      name: :material_lots_lot_no_index,
      message: "이미 존재하는 LOT 번호입니다"
    )
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, "available")
      _ -> changeset
    end
  end

  @doc """
  상태 전이 전용 changeset. 허용 전이표 검증 + 멱등(no-op) 전이 거부.
  (WorkOrder.transition_changeset 패턴 그대로 — *_at 컬럼은 LOT 에 없으므로 타임스탬프 기록 없음.)
  """
  def transition_changeset(%__MODULE__{status: from} = lot, to) do
    base =
      lot
      |> cast(%{status: to}, [:status])
      |> validate_required([:status], message: "필수 항목입니다")
      |> validate_inclusion(:status, @statuses, message: "허용되지 않은 상태값입니다")

    cond do
      from == to ->
        add_error(base, :status, "이미 #{to} 상태입니다 (동일 상태로의 전이는 허용되지 않습니다)")

      true ->
        validate_change(base, :status, fn :status, new_status ->
          if MaterialLotStateMachine.can_transition?(from, new_status) do
            []
          else
            [status: "허용되지 않은 상태 전이입니다: #{from} → #{new_status}"]
          end
        end)
    end
  end
end
