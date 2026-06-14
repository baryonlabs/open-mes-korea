defmodule OpenMes.Lots.LotConsumption do
  @moduledoc """
  LOT 투입 기록(LotConsumption) Ecto 스키마 + changeset — append-only.

  자재 소비는 이 테이블 경유만(암묵 소비 금지). 생성만 제공(수정/삭제 미제공).
  genealogy: 제품LOT.source_operation_id → operation → lot_consumptions → input_lot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lot_consumptions" do
    field :operation_id, :binary_id
    field :input_lot_id, :binary_id
    field :quantity, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "투입 기록 생성용 changeset. quantity 는 0 보다 커야 한다."
  def create_changeset(consumption \\ %__MODULE__{}, attrs) do
    consumption
    |> cast(attrs, [:operation_id, :input_lot_id, :quantity])
    |> validate_required([:operation_id, :input_lot_id, :quantity], message: "필수 항목입니다")
    |> validate_number(:quantity, greater_than: 0, message: "투입 수량은 0 보다 커야 합니다")
    |> foreign_key_constraint(:operation_id, message: "존재하지 않는 공정입니다")
    |> foreign_key_constraint(:input_lot_id, message: "존재하지 않는 LOT 입니다")
  end
end
