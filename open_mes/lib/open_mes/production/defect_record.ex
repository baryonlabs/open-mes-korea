defmodule OpenMes.Production.DefectRecord do
  @moduledoc """
  불량 기록(DefectRecord) Ecto 스키마 + changeset — append-only.

  생성만 제공한다(수정/삭제 미제공). 특정 ProductionResult 에 귀속.
  애드온 계약(defect_stats): production_result_id, defect_code, quantity, note.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "defect_records" do
    field :production_result_id, :binary_id
    field :defect_code, :string
    field :quantity, :decimal
    field :note, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "불량 기록 생성용 changeset. quantity 는 0 보다 커야 한다."
  def create_changeset(record \\ %__MODULE__{}, attrs) do
    record
    |> cast(attrs, [:production_result_id, :defect_code, :quantity, :note])
    |> validate_required([:production_result_id, :defect_code, :quantity], message: "필수 항목입니다")
    |> validate_number(:quantity, greater_than: 0, message: "불량 수량은 0 보다 커야 합니다")
    |> foreign_key_constraint(:production_result_id, message: "존재하지 않는 공정 실적입니다")
  end
end
