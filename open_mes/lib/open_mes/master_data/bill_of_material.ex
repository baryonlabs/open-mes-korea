defmodule OpenMes.MasterData.BillOfMaterial do
  @moduledoc """
  BOM(BillOfMaterial) Ecto 스키마 + changeset — 기준정보.

  parent_item_id 가 child_item_id 를 quantity 만큼 필요로 한다.
  loss_rate 는 0..1(공정 손실률). 동일 부모-자식 중복 금지(unique).
  변경 시 AuditLog 필수.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bills_of_material" do
    field :parent_item_id, :binary_id
    field :child_item_id, :binary_id
    field :quantity, :decimal
    field :loss_rate, :decimal, default: Decimal.new(0)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "BOM 생성/수정용 changeset."
  def changeset(bom, attrs) do
    bom
    |> cast(attrs, [:parent_item_id, :child_item_id, :quantity, :loss_rate])
    |> validate_required([:parent_item_id, :child_item_id, :quantity], message: "필수 항목입니다")
    |> validate_number(:quantity, greater_than: 0, message: "수량은 0 보다 커야 합니다")
    |> validate_number(:loss_rate,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1,
      message: "손실률은 0 이상 1 이하여야 합니다"
    )
    |> validate_not_self_reference()
    |> foreign_key_constraint(:parent_item_id, message: "존재하지 않는 부모 품목입니다")
    |> foreign_key_constraint(:child_item_id, message: "존재하지 않는 자식 품목입니다")
    |> unique_constraint([:parent_item_id, :child_item_id],
      name: :bills_of_material_parent_item_id_child_item_id_index,
      message: "이미 등록된 부모-자식 품목 조합입니다"
    )
  end

  # 자기 자신을 구성품으로 두는 BOM 금지(순환 방지의 최소 가드).
  defp validate_not_self_reference(changeset) do
    parent = get_field(changeset, :parent_item_id)
    child = get_field(changeset, :child_item_id)

    if not is_nil(parent) and parent == child do
      add_error(changeset, :child_item_id, "부모 품목과 동일한 자식 품목은 등록할 수 없습니다")
    else
      changeset
    end
  end
end
