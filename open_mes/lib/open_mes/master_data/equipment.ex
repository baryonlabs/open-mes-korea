defmodule OpenMes.MasterData.Equipment do
  @moduledoc """
  설비(Equipment) Ecto 스키마 + changeset — 기준정보(최소안).
  변경 시 AuditLog 필수.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "equipment" do
    field :equipment_code, :string
    field :name, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "설비 생성/수정용 changeset."
  def changeset(equipment, attrs) do
    equipment
    |> cast(attrs, [:equipment_code, :name, :active])
    |> validate_required([:equipment_code, :name], message: "필수 항목입니다")
    |> unique_constraint(:equipment_code,
      name: :equipment_equipment_code_index,
      message: "이미 존재하는 설비 코드입니다"
    )
  end
end
