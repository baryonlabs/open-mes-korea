defmodule OpenMes.MasterData.Worker do
  @moduledoc """
  작업자(Worker) Ecto 스키마 + changeset — 기준정보(최소안).
  변경 시 AuditLog 필수.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # 공장 역할(role) 5종 — 화면 가시성/인가의 자연 속성(설계 §1.3).
  # 영문 식별자, 화면 표기는 한국어(OpenMesWeb.Authorization 단일 정의).
  @roles ~w(system_admin production_manager quality_manager material_manager operator)

  @doc "허용 role 식별자 목록(영문)."
  def roles, do: @roles

  schema "workers" do
    field :worker_code, :string
    field :name, :string
    field :role, :string, default: "operator"
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "작업자 생성/수정용 changeset."
  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:worker_code, :name, :role, :active])
    |> validate_required([:worker_code, :name], message: "필수 항목입니다")
    |> validate_inclusion(:role, @roles, message: "허용되지 않은 역할입니다")
    |> unique_constraint(:worker_code,
      name: :workers_worker_code_index,
      message: "이미 존재하는 작업자 코드입니다"
    )
  end
end
