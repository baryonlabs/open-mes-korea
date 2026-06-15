defmodule OpenMes.Knowledge.KnowledgeDocument do
  @moduledoc """
  지식 문서(KnowledgeDocument) Ecto 스키마 + changeset — 설계 27번 §1.2.

  OKF(Open Knowledge Format) 개념 문서를 DB 단일 원천으로 보관한다(번들은 import/export 표현).

  불변식:
    - `okf_type` 필수(OKF `type` 필수에 대응). 나머지는 권장/선택(관용적 소비).
    - 삭제 없음 — 비활성화는 `active=false`(이력 보존, MasterData 동형).
    - 변경 시 AuditLog 필수(컨텍스트가 보장 = OKF `log.md` 대응).
    - 미지 프론트매터 필드는 `extra`(jsonb)에 보존(round-trip).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @required [:okf_type, :uploaded_by]
  @optional [:title, :description, :resource, :tags, :body, :extra, :version, :valid_until, :active]

  schema "knowledge_documents" do
    field :okf_type, :string
    field :title, :string
    field :description, :string
    field :resource, :string
    field :tags, {:array, :string}, default: []
    field :body, :string, default: ""
    field :extra, :map, default: %{}
    field :version, :string
    field :uploaded_by, :string
    field :valid_until, :date
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "지식 문서 생성/수정용 changeset. okf_type/uploaded_by 필수."
  def changeset(document, attrs) do
    document
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required, message: "필수 항목입니다")
    |> validate_length(:okf_type, max: 100, message: "OKF 유형은 100자 이하여야 합니다")
    |> unique_constraint(:resource,
      name: :knowledge_documents_resource_index,
      message: "이미 존재하는 resource URI 입니다"
    )
  end
end
