defmodule OpenMes.Audit do
  @moduledoc """
  감사(Audit) 컨텍스트 — AuditLog 기록 헬퍼.

  설계 원칙:
    - AuditLog 는 컨트롤러가 아니라, 도메인 변경을 수행하는 컨텍스트 함수 내부의
      동일 `Ecto.Multi` 안에서 생성한다. 따라서 본 모듈은 "Multi 스텝"을 만들어 주는
      함수를 제공한다(직접 Repo.insert 하지 않음).
    - append-only: update/delete 함수를 제공하지 않는다.
  """
  alias Ecto.Multi
  alias OpenMes.Audit.AuditLog

  @doc """
  주어진 `Ecto.Multi` 에 감사 로그 INSERT 스텝을 추가한다.

  `attrs_fun` 은 이전 스텝 결과(map)를 받아 AuditLog 속성 map 을 반환하는 함수다.
  이를 통해 같은 트랜잭션에서 갓 변경된 레코드(before/after)를 참조할 수 있다.

  ## 예시

      multi
      |> OpenMes.Audit.put_log(:audit, fn %{transition: wo} ->
        %{
          actor_id: actor_id,
          action: "work_order.release",
          resource_type: "work_order",
          resource_id: wo.id,
          before: %{status: "draft"},
          after: %{status: wo.status, released_at: wo.released_at}
        }
      end)
  """
  def put_log(%Multi{} = multi, step_name, attrs_fun) when is_function(attrs_fun, 1) do
    Multi.insert(multi, step_name, fn changes ->
      changes
      |> attrs_fun.()
      |> AuditLog.changeset()
    end)
  end
end
