defmodule OpenMes.DataCase do
  @moduledoc """
  DB 연동 테스트용 케이스 템플릿(Ecto SQL Sandbox).

  코어 산출물(02_domain_engineer_workorder_impl)의 DataCase 와 동일 패턴.
  EXT-2 테스트는 같은 OpenMes.Repo 를 공유한다(테이블 레벨 분리).

  phx.new 표준 헬퍼(`errors_on/1`, `setup_sandbox/1`)를 포함한다.
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
    OpenMes.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Ecto SQL Sandbox 를 설정한다. async 가 아니면 shared 모드로 동작한다.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OpenMes.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  changeset 에 누적된 에러를 필드별 메시지 맵으로 변환하는 헬퍼.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "should be at least 12 character(s)" in errors_on(changeset).password
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
