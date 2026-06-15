defmodule OpenMes.Production do
  @moduledoc """
  생산관리(Production) 바운디드 컨텍스트 — WorkOrder 유스케이스의 유일한 공개 진입점.

  핵심 불변식:
    - 상태 변경 + AuditLog + (필요 시) Outbox 이벤트는 반드시 단일 `Ecto.Multi`(=단일 트랜잭션).
      하나라도 실패하면 전부 롤백된다.
    - 모든 쓰기 함수는 actor_id 를 명시적으로 받는다(actor 없는 쓰기 금지).
    - 상태 전이는 WorkOrder.transition_changeset 을 통해서만(허용 전이표 강제).
    - Outbox 이벤트는 문서에 정의된 work_order.released 만 발행한다(start/complete/cancel 미발행).

  컨트롤러는 이 모듈만 호출하며, AuditLog/Outbox 를 직접 만들지 않는다.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit
  alias OpenMes.Outbox
  alias OpenMes.Production.WorkOrder
  alias OpenMes.Repo

  # ──────────────────────────────────────────────────────────────────
  # 조회 (읽기 — AuditLog 불필요)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  작업지시 목록 조회. status / item_id / due_date 필터와 limit/offset 페이지네이션 지원.
  """
  def list_work_orders(filters \\ %{}) do
    WorkOrder
    |> filter_by_status(filters)
    |> filter_by_item(filters)
    |> filter_by_due_date(filters)
    |> order_by_recent()
    |> paginate(filters)
    |> Repo.all()
  end

  @doc "작업지시 단건 조회. 없으면 nil."
  def get_work_order(id), do: Repo.get(WorkOrder, id)

  @doc "작업지시 단건 조회. 없으면 {:error, :not_found}."
  def fetch_work_order(id) do
    case Repo.get(WorkOrder, id) do
      nil -> {:error, :not_found}
      wo -> {:ok, wo}
    end
  end

  defp filter_by_status(query, %{"status" => status}) when is_binary(status) and status != "",
    do: from(w in query, where: w.status == ^status)

  defp filter_by_status(query, _), do: query

  defp filter_by_item(query, %{"item_id" => item_id}) when is_binary(item_id) and item_id != "",
    do: from(w in query, where: w.item_id == ^item_id)

  defp filter_by_item(query, _), do: query

  defp filter_by_due_date(query, %{"due_date" => due_date})
       when is_binary(due_date) and due_date != "",
       do: from(w in query, where: w.due_date == ^due_date)

  defp filter_by_due_date(query, _), do: query

  defp order_by_recent(query), do: from(w in query, order_by: [desc: w.inserted_at])

  defp paginate(query, filters) do
    limit = parse_int(Map.get(filters, "limit"), 50) |> min(200) |> max(1)
    offset = parse_int(Map.get(filters, "offset"), 0) |> max(0)
    from(w in query, limit: ^limit, offset: ^offset)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 생성 (AuditLog 생성, Outbox 이벤트 없음 — 문서 이벤트 목록에 생성 이벤트 없음)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  작업지시 생성. 항상 draft 상태로 생성되며, 동일 트랜잭션에서 AuditLog(work_order.create) 1건을 남긴다.
  """
  def create_work_order(attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:work_order, WorkOrder.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{work_order: wo} ->
      %{
        actor_id: actor_id,
        action: "work_order.create",
        resource_type: "work_order",
        resource_id: wo.id,
        before: nil,
        after: snapshot_full(wo)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:work_order)
  end

  @doc """
  작업지시 필드 수정(planned_quantity, due_date). draft 상태에서만 허용.
  동일 트랜잭션에서 AuditLog(work_order.update) 1건을 남긴다.
  """
  def update_work_order(id, attrs, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load_work_order(repo, id) end)
    |> Multi.update(:work_order, fn %{load: wo} ->
      WorkOrder.update_changeset(wo, attrs)
    end)
    |> Audit.put_log(:audit, fn %{load: before_wo, work_order: after_wo} ->
      %{
        actor_id: actor_id,
        action: "work_order.update",
        resource_type: "work_order",
        resource_id: after_wo.id,
        before: snapshot_full(before_wo),
        after: snapshot_full(after_wo)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:work_order)
  end

  # ──────────────────────────────────────────────────────────────────
  # 상태 전이
  # ──────────────────────────────────────────────────────────────────

  @doc "draft → released. AuditLog + work_order.released 이벤트(Outbox)를 동일 트랜잭션으로 생성."
  def release_work_order(id, actor_id) do
    id
    |> transition_multi("released", "work_order.release", actor_id)
    # release 만 Outbox 이벤트를 발행한다(문서 정의 이벤트).
    |> Outbox.put_event(:event, fn %{transition: wo} ->
      %{
        event_type: "work_order.released",
        aggregate_type: "work_order",
        aggregate_id: wo.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          work_order_id: wo.id,
          work_order_no: wo.work_order_no,
          item_id: wo.item_id,
          # decimal 은 정밀도 보존을 위해 문자열로 직렬화
          planned_quantity: Decimal.to_string(wo.planned_quantity),
          released_at: wo.released_at,
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  @doc "released → in_progress. AuditLog 생성(Outbox 이벤트 없음 — 문서 미정의)."
  def start_work_order(id, actor_id) do
    id
    |> transition_multi("in_progress", "work_order.start", actor_id)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  @doc "in_progress → completed. AuditLog 생성(Outbox 이벤트 없음 — 문서 미정의)."
  def complete_work_order(id, actor_id) do
    id
    |> transition_multi("completed", "work_order.complete", actor_id)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  @doc "* → cancelled. AuditLog 생성(Outbox 이벤트 없음 — 문서 미정의)."
  def cancel_work_order(id, actor_id) do
    id
    |> transition_multi("cancelled", "work_order.cancel", actor_id)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  # 상태 전이 공통 Multi 골격: 레코드 로드 → 전이 update → AuditLog insert.
  # (release 의 경우 호출부에서 Outbox 이벤트 스텝을 추가로 끼워 넣는다.)
  defp transition_multi(id, to_status, action, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load_work_order(repo, id) end)
    |> Multi.update(:transition, fn %{load: wo} ->
      WorkOrder.transition_changeset(wo, to_status)
    end)
    |> Audit.put_log(:audit, fn %{load: before_wo, transition: after_wo} ->
      %{
        actor_id: actor_id,
        action: action,
        resource_type: "work_order",
        resource_id: after_wo.id,
        before: %{status: before_wo.status},
        after: snapshot_transition(after_wo)
      }
    end)
  end

  defp load_work_order(repo, id) do
    case repo.get(WorkOrder, id) do
      nil -> {:error, :not_found}
      wo -> {:ok, wo}
    end
  end

  # 트랜잭션 결과 정규화: {:ok, %{step => wo}} → {:ok, wo}
  # not_found / changeset 실패는 {:error, ...} 로 변환하여 컨트롤러가 단순 분기.
  defp normalize_result({:ok, changes}, result_key), do: {:ok, Map.fetch!(changes, result_key)}

  defp normalize_result({:error, :load, :not_found, _changes}, _key),
    do: {:error, :not_found}

  defp normalize_result({:error, _failed_step, %Ecto.Changeset{} = changeset, _changes}, _key),
    do: {:error, changeset}

  defp normalize_result({:error, _failed_step, reason, _changes}, _key),
    do: {:error, reason}

  # create/update 용 전체 스냅샷(주요 필드)
  defp snapshot_full(%WorkOrder{} = wo) do
    %{
      work_order_no: wo.work_order_no,
      item_id: wo.item_id,
      planned_quantity: decimal_to_string(wo.planned_quantity),
      due_date: wo.due_date,
      status: wo.status
    }
  end

  # 상태 전이용 슬림 스냅샷(status + 전이 타임스탬프)
  defp snapshot_transition(%WorkOrder{} = wo) do
    %{
      status: wo.status,
      released_at: wo.released_at,
      started_at: wo.started_at,
      completed_at: wo.completed_at,
      cancelled_at: wo.cancelled_at
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
end
