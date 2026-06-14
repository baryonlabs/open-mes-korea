defmodule OpenMes.Production.ProductionResult do
  @moduledoc """
  공정 실적(ProductionResult) Ecto 스키마 + changeset — append-only.

  생성만 제공한다(수정/삭제 미제공 — 정정은 새 레코드, 설계 §0-6).
  애드온 계약: operation_id, worker_id, equipment_id, good_quantity, defect_quantity,
  started_at, ended_at. (operations.completed_at 과 명칭 구분 — 여기는 ended_at.)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "production_results" do
    field :operation_id, :binary_id
    field :worker_id, :binary_id
    field :equipment_id, :binary_id
    field :good_quantity, :decimal, default: Decimal.new(0)
    field :defect_quantity, :decimal, default: Decimal.new(0)
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  실적 생성용 changeset. operation_id 는 코어 쓰기 경로에서 필수(DB 는 nullable — 애드온 호환).
  good/defect 수량은 0 이상.
  """
  def create_changeset(result \\ %__MODULE__{}, attrs) do
    result
    |> cast(attrs, [
      :operation_id,
      :worker_id,
      :equipment_id,
      :good_quantity,
      :defect_quantity,
      :started_at,
      :ended_at
    ])
    |> validate_required([:operation_id], message: "필수 항목입니다")
    |> validate_number(:good_quantity,
      greater_than_or_equal_to: 0,
      message: "양품 수량은 0 이상이어야 합니다"
    )
    |> validate_number(:defect_quantity,
      greater_than_or_equal_to: 0,
      message: "불량 수량은 0 이상이어야 합니다"
    )
    |> foreign_key_constraint(:operation_id, message: "존재하지 않는 공정입니다")
    |> foreign_key_constraint(:worker_id, message: "존재하지 않는 작업자입니다")
    |> foreign_key_constraint(:equipment_id, message: "존재하지 않는 설비입니다")
  end
end
