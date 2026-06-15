defmodule OpenMes.Ingest.DeadLetterRecord do
  @moduledoc """
  ingest_dead_letters 격리 레코드 Ecto 스키마. 설계 §5.2.

  검증 실패(오염) 메시지를 원본 그대로 보존한다. append-only(정정/삭제 함수 없음).
  코어 audit_logs 와 무관 — 도메인 이력이 아니라 수집 오류 격리소다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # append-only — updated_at 없음
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "ingest_dead_letters" do
    field :raw_payload, :map
    field :reason, :string
    field :source, :string

    timestamps()
  end

  @doc "격리 레코드 changeset. raw_payload 와 reason 은 필수."
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:raw_payload, :reason, :source])
    |> validate_required([:raw_payload, :reason])
  end
end
