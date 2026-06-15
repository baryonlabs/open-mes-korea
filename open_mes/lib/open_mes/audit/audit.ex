defmodule OpenMes.Audit do
  @moduledoc """
  감사(Audit) 컨텍스트 — AuditLog 기록 헬퍼.

  설계 원칙:
    - AuditLog 는 컨트롤러가 아니라, 도메인 변경을 수행하는 컨텍스트 함수 내부의
      동일 `Ecto.Multi` 안에서 생성한다. 따라서 본 모듈은 "Multi 스텝"을 만들어 주는
      함수를 제공한다(직접 Repo.insert 하지 않음).
    - append-only: update/delete 함수를 제공하지 않는다.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit.AuditLog
  alias OpenMes.Repo

  # ──────────────────────────────────────────────────────────────────
  # 조회 (읽기 전용 — G6 감사 로그 조회. AuditLog 무관)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  감사 로그 목록(최근순). 읽기 전용.

  필터(모두 선택):
    - "resource_type" : 리소스 유형 정확히 일치(예: work_order, material_lot)
    - "action"        : 액션 정확히 일치(예: work_order.release)
    - "actor_id"      : 작업자(actor) 부분 일치
    - "from"/"to"     : 기록 시각(inserted_at) 기간(Date 또는 ISO 문자열, to 는 종료일 포함)
    - "limit"/"offset": 페이지네이션(기본 50, 최대 200)
  """
  def list_audit_logs(filters \\ %{}) do
    AuditLog
    |> filter_resource_type(filters)
    |> filter_action(filters)
    |> filter_actor(filters)
    |> filter_from(filters)
    |> filter_to(filters)
    |> from_order_recent()
    |> from_paginate(filters)
    |> Repo.all()
  end

  @doc "감사 로그에 등록된 distinct resource_type 목록(필터 셀렉트용)."
  def list_resource_types do
    from(a in AuditLog, distinct: true, select: a.resource_type, order_by: a.resource_type)
    |> Repo.all()
  end

  defp filter_resource_type(query, %{"resource_type" => rt}) when is_binary(rt) and rt != "",
    do: from(a in query, where: a.resource_type == ^rt)

  defp filter_resource_type(query, _), do: query

  defp filter_action(query, %{"action" => action}) when is_binary(action) and action != "",
    do: from(a in query, where: a.action == ^action)

  defp filter_action(query, _), do: query

  defp filter_actor(query, %{"actor_id" => actor}) when is_binary(actor) and actor != "" do
    like = "%" <> actor <> "%"
    from(a in query, where: like(a.actor_id, ^like))
  end

  defp filter_actor(query, _), do: query

  defp filter_from(query, %{"from" => from_val}) do
    case to_datetime_start(from_val) do
      nil -> query
      dt -> from(a in query, where: a.inserted_at >= ^dt)
    end
  end

  defp filter_from(query, _), do: query

  defp filter_to(query, %{"to" => to_val}) do
    case to_datetime_end(to_val) do
      nil -> query
      dt -> from(a in query, where: a.inserted_at <= ^dt)
    end
  end

  defp filter_to(query, _), do: query

  defp from_order_recent(query), do: from(a in query, order_by: [desc: a.inserted_at])

  defp from_paginate(query, filters) do
    limit = parse_int(Map.get(filters, "limit"), 50) |> min(200) |> max(1)
    offset = parse_int(Map.get(filters, "offset"), 0) |> max(0)
    from(a in query, limit: ^limit, offset: ^offset)
  end

  # 기간 경계: Date/ISO 문자열을 UTC DateTime 으로(빈/부정 입력은 nil → 필터 미적용).
  defp to_datetime_start(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")
  defp to_datetime_start(s) when is_binary(s) and s != "", do: parse_date_boundary(s, :start)
  defp to_datetime_start(_), do: nil

  defp to_datetime_end(%Date{} = d), do: DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")
  defp to_datetime_end(s) when is_binary(s) and s != "", do: parse_date_boundary(s, :end)
  defp to_datetime_end(_), do: nil

  defp parse_date_boundary(s, edge) do
    case Date.from_iso8601(s) do
      {:ok, d} when edge == :start -> DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")
      {:ok, d} -> DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

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
