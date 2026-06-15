defmodule OpenMes.Repo.Migrations.CreateAiInteractions do
  @moduledoc """
  AI 상호작용(ai_interactions) 테이블 — 설계 23번 §A.1.

  모든 AI 상호작용의 감사 레코드이자 propose→승인→실행 상태머신의 보유자.
  AI 는 직접 쓰기 없이 이 레코드(제안 diff)만 만들고, 실제 적용은 인간 승인 후
  apply_proposal 에서만 수행된다(CLAUDE.md AI 안전 원칙).
  """
  use Ecto.Migration

  def change do
    create table(:ai_interactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, :string, null: false
      add :intent, :string, null: false
      add :prompt, :text, null: false
      add :response_summary, :text
      add :referenced_resources, :map
      add :proposed_action, :map
      add :approval_status, :string, null: false, default: "proposed"
      add :provider, :string
      add :reviewer_id, :string
      add :reviewed_at, :utc_datetime_usec
      add :execution_result, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_interactions, [:approval_status])
    create index(:ai_interactions, [:actor_id])
    create index(:ai_interactions, [:inserted_at])
  end
end
