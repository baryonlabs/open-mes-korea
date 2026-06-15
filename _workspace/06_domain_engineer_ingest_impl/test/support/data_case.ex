defmodule OpenMes.DataCase do
  @moduledoc """
  컨텍스트/스키마 테스트용 케이스 템플릿.

  Ecto SQL Sandbox 로 각 테스트를 격리된 트랜잭션 안에서 실행한다.
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

  @doc "테스트별 DB 샌드박스 설정(async 지원)."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OpenMes.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  changeset 의 에러를 {필드 => [메시지...]} 형태로 펼친다.

      assert errors_on(changeset)[:status]
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
