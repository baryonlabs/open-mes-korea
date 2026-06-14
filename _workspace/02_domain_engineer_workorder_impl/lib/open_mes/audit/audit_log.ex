defmodule OpenMes.Audit.AuditLog do
  @moduledoc """
  감사 로그 Ecto 스키마.

  모든 쓰기 작업의 변경 이력을 담는 append-only 레코드.
  before/after 는 jsonb(map) 스냅샷이며, 생성 작업의 before 는 nil 이다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field :actor_id, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :before, :map
    field :after, :map

    # append-only: updated_at 없음
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required [:actor_id, :action, :resource_type, :resource_id]
  @optional [:before, :after]

  @doc """
  감사 로그 생성용 changeset.

  before/after 를 제외한 모든 필드는 필수이며, actor_id 는 빈 문자열을 허용하지 않는다.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required, message: "필수 항목입니다")
    |> validate_change(:actor_id, fn :actor_id, value ->
      if is_binary(value) and String.trim(value) != "",
        do: [],
        else: [actor_id: "actor_id 는 비어 있을 수 없습니다"]
    end)
  end
end
