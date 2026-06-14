defmodule OpenMes.DataCase do
  @moduledoc """
  DB 연동 테스트용 케이스 템플릿(Ecto SQL Sandbox).

  코어 산출물(02_domain_engineer_workorder_impl)의 DataCase 와 동일 패턴.
  EXT-2 테스트는 같은 OpenMes.Repo 를 공유한다(테이블 레벨 분리).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias OpenMes.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OpenMes.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OpenMes.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
