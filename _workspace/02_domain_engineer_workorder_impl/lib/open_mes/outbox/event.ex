defmodule OpenMes.Outbox.Event do
  @moduledoc """
  이벤트 아웃박스 Ecto 스키마.

  상태 변경과 동일 트랜잭션으로 적재되는 도메인 이벤트 레코드.
  MVP 단계에서는 적재만 하며 외부 발행은 하지 않으므로 status 는 항상 "pending".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending published)

  schema "outbox_events" do
    field :event_type, :string
    field :aggregate_type, :string
    field :aggregate_id, :binary_id
    field :payload, :map
    field :status, :string, default: "pending"
    field :occurred_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec

    # append-only: updated_at 없음
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required [:event_type, :aggregate_type, :aggregate_id, :payload, :occurred_at]
  @optional [:status, :published_at]

  @doc """
  아웃박스 이벤트 생성용 changeset.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required, message: "필수 항목입니다")
    |> validate_inclusion(:status, @statuses, message: "허용되지 않은 발행 상태입니다")
  end
end
