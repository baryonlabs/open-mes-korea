defmodule OpenMes.Repo.Migrations.CreateProcesses do
  @moduledoc """
  공정(processes) 테이블 생성 — 기준정보.

  docs/domain-model.md Process 정의 + 설계 §1.3(3).
  """
  use Ecto.Migration

  def change do
    create table(:processes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :process_code, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:processes, [:process_code])
    create index(:processes, [:active])
  end
end
