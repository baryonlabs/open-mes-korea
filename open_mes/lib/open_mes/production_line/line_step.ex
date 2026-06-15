defmodule OpenMes.ProductionLine.LineStep do
  @moduledoc """
  라인 공정 단계(ProductionLineStep) Ecto 스키마 + changeset.

  "이 라인의 N번째 공정은 process_id, 대표 설비는 equipment_id" 매핑.
  Routing(품목별 생산 실행 순서)과 무관 — 라인 모니터 표시 구성만 담는다.
  process_id 필수(모니터 노드), equipment_id 선택(없으면 모니터 unknown).
  라인 내 sequence 유일. 변경 시 AuditLog 필수(ProductionLine 컨텍스트 경유).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "production_line_steps" do
    field :line_id, :binary_id
    field :process_id, :binary_id
    field :equipment_id, :binary_id
    field :sequence, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc "라인 공정 단계 생성/수정용 changeset."
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:line_id, :process_id, :equipment_id, :sequence])
    |> validate_required([:line_id, :process_id, :sequence], message: "필수 항목입니다")
    |> validate_number(:sequence, greater_than: 0, message: "순서는 0 보다 커야 합니다")
    |> foreign_key_constraint(:line_id, message: "존재하지 않는 라인입니다")
    |> foreign_key_constraint(:process_id, message: "존재하지 않는 공정입니다")
    |> foreign_key_constraint(:equipment_id, message: "존재하지 않는 설비입니다")
    |> unique_constraint([:line_id, :sequence],
      name: :production_line_steps_line_id_sequence_index,
      message: "이미 사용 중인 순서입니다"
    )
  end
end
