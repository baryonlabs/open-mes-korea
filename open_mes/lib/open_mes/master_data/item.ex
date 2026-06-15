defmodule OpenMes.MasterData.Item do
  @moduledoc """
  품목(Item) Ecto 스키마 + changeset — 기준정보.

  item_type: raw(원자재)/semi(반제품)/product(제품).
  CRUD 허용(이력 보존을 위해 삭제 대신 active=false 권장). 변경 시 AuditLog 필수.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @item_types ~w(raw semi product)

  schema "items" do
    field :item_code, :string
    field :name, :string
    field :item_type, :string
    field :unit, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "정의된 품목 유형 목록(raw/semi/product)."
  def item_types, do: @item_types

  @doc "품목 생성/수정용 changeset."
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:item_code, :name, :item_type, :unit, :active])
    |> validate_required([:item_code, :name, :item_type, :unit], message: "필수 항목입니다")
    |> validate_inclusion(:item_type, @item_types, message: "허용되지 않은 품목 유형입니다")
    |> unique_constraint(:item_code,
      name: :items_item_code_index,
      message: "이미 존재하는 품목 코드입니다"
    )
  end
end
