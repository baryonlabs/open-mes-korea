defmodule OpenMes.Repo.Migrations.CreateWorkers do
  @moduledoc """
  작업자(workers) 테이블 생성 — 기준정보(신설).

  설계 §1.3(6) / §8 최소안(code/name/active). ProductionResult.worker_id 가 참조.
  """
  use Ecto.Migration

  def change do
    create table(:workers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :worker_code, :string, null: false
      add :name, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workers, [:worker_code])
    create index(:workers, [:active])
  end
end
