defmodule OpenMes.ProductionLine.Line do
  @moduledoc """
  생산라인(ProductionLine) Ecto 스키마 + changeset — 라인 모니터 표시 단위.

  라인 = 공정·설비를 조합한 모니터링 구성(configuration). 기준정보 6종과 달리
  단계 컬렉션을 가진 집합체. 변경 시 AuditLog 필수(ProductionLine 컨텍스트 경유).
  삭제 없음(이력 보존) — active=false 로 비활성.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "production_lines" do
    field :line_code, :string
    field :name, :string
    field :description, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "생산라인 생성/수정용 changeset."
  def changeset(line, attrs) do
    line
    |> cast(attrs, [:line_code, :name, :description, :active])
    |> validate_required([:line_code, :name], message: "필수 항목입니다")
    |> unique_constraint(:line_code,
      name: :production_lines_line_code_index,
      message: "이미 존재하는 라인 코드입니다"
    )
  end
end
