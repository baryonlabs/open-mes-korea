defmodule OpenMes.MasterData.Routing do
  @moduledoc """
  라우팅(Routing) Ecto 스키마 + changeset — 기준정보.

  품목(item_id)별 공정(process_id) 순서(sequence). 품목 내 순서 유일.
  standard_cycle_time(초/개)은 선택. 변경 시 AuditLog 필수.
  애드온 계약(equipment_oee): item_id, process_id, sequence, standard_cycle_time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routings" do
    field :item_id, :binary_id
    field :process_id, :binary_id
    field :sequence, :integer
    field :standard_cycle_time, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "라우팅 생성/수정용 changeset."
  def changeset(routing, attrs) do
    routing
    |> cast(attrs, [:item_id, :process_id, :sequence, :standard_cycle_time])
    |> validate_required([:item_id, :process_id, :sequence], message: "필수 항목입니다")
    |> validate_number(:sequence, greater_than: 0, message: "순서는 0 보다 커야 합니다")
    |> validate_number(:standard_cycle_time,
      greater_than_or_equal_to: 0,
      message: "표준 사이클 타임은 0 이상이어야 합니다"
    )
    |> foreign_key_constraint(:item_id, message: "존재하지 않는 품목입니다")
    |> foreign_key_constraint(:process_id, message: "존재하지 않는 공정입니다")
    |> unique_constraint([:item_id, :sequence],
      name: :routings_item_id_sequence_index,
      message: "이미 등록된 품목-순서 조합입니다"
    )
  end
end
