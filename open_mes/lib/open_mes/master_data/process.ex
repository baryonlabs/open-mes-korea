defmodule OpenMes.MasterData.Process do
  @moduledoc """
  공정(Process) Ecto 스키마 + changeset — 기준정보.
  변경 시 AuditLog 필수.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "processes" do
    field :process_code, :string
    field :name, :string
    field :description, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "공정 생성/수정용 changeset."
  def changeset(process, attrs) do
    process
    |> cast(attrs, [:process_code, :name, :description, :active])
    |> validate_required([:process_code, :name], message: "필수 항목입니다")
    |> unique_constraint(:process_code,
      name: :processes_process_code_index,
      message: "이미 존재하는 공정 코드입니다"
    )
  end
end
