defmodule OpenMes.Repo.Migrations.AddRoleToWorkers do
  @moduledoc """
  작업자(workers)에 role 컬럼 추가 — 공장 역할별 화면 분리(설계 §1.3, §7.1).

  코어 비침투: 기준정보 작업자의 자연 속성 1필드만 추가한다.
  role 5종: system_admin / production_manager / quality_manager / material_manager / operator.
  기본값 operator, NOT NULL, CHECK 제약으로 5종 외 값 차단.
  """
  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :role, :string, null: false, default: "operator"
    end

    create constraint(:workers, :workers_role_check,
             check:
               "role IN ('system_admin','production_manager','quality_manager','material_manager','operator')"
           )

    create index(:workers, [:role])
  end
end
