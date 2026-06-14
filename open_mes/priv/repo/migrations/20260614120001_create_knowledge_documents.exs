defmodule OpenMes.Repo.Migrations.CreateKnowledgeDocuments do
  @moduledoc """
  지식베이스(OKF 문서) 테이블 — 설계 27번 §1.3.

  RAG 문서 영역을 생산 데이터와 분리된 OKF(Open Knowledge Format) 문서로 보관한다.
  okf_type 만 NOT NULL(OKF 필수), 나머지는 권장/선택(관용적 소비). tags GIN 인덱스로
  설비/공정 코드 ↔ 문서 매칭(AI 조사 검색 핵심). resource partial unique(있으면 유일).
  """
  use Ecto.Migration

  def change do
    create table(:knowledge_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :okf_type, :string, null: false
      add :title, :string
      add :description, :string
      add :resource, :string
      add :tags, {:array, :string}, null: false, default: []
      add :body, :text, null: false, default: ""
      add :extra, :map, null: false, default: %{}
      add :version, :string
      add :uploaded_by, :string, null: false
      add :valid_until, :date
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:knowledge_documents, [:okf_type])
    create index(:knowledge_documents, [:active])
    # tags 배열 검색(설비 EQ-P03 / 공정 P-INJECTION 매칭) — GIN.
    create index(:knowledge_documents, [:tags], using: "gin")
    # resource 있으면 유일(OKF 정규 URI), nil 허용(권장 필드).
    create unique_index(:knowledge_documents, [:resource],
             where: "resource IS NOT NULL",
             name: :knowledge_documents_resource_index
           )
  end
end
