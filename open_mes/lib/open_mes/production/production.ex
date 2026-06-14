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
  alias OpenMes.Production.{DefectRecord, Operation, ProductionResult, WorkOrder}
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

  # ════════════════════════════════════════════════════════════════════
  # Operation (공정 실행 단위) — 상태머신 + AuditLog + Outbox
  # ════════════════════════════════════════════════════════════════════

  @doc "특정 작업지시의 공정 목록(순서 오름차순)."
  def list_operations(work_order_id) do
    from(o in Operation, where: o.work_order_id == ^work_order_id, order_by: [asc: o.sequence])
    |> Repo.all()
  end

  @doc "공정 단건 조회. 없으면 nil."
  def get_operation(id), do: Repo.get(Operation, id)

  @doc "공정 단건 조회. 없으면 {:error, :not_found}."
  def fetch_operation(id), do: fetch(Operation, id)

  @doc """
  공정 생성. 항상 pending 상태로 생성되며, 동일 트랜잭션에서 AuditLog(operation.create) 1건을 남긴다.
  (Outbox 이벤트 없음 — 문서 미정의.)
  """
  def create_operation(attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:operation, Operation.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{operation: op} ->
      %{
        actor_id: actor_id,
        action: "operation.create",
        resource_type: "operation",
        resource_id: op.id,
        before: nil,
        after: operation_snapshot(op)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:operation)
  end

  @doc "pending → ready. AuditLog 만(문서 미정의 → Outbox 없음)."
  def ready_operation(id, actor_id),
    do: operation_transition(id, "ready", "operation.ready", actor_id)

  @doc "running → paused. AuditLog 만(문서 미정의 → Outbox 없음)."
  def pause_operation(id, actor_id),
    do: operation_transition(id, "paused", "operation.pause", actor_id)

  @doc "* → skipped. AuditLog 만(문서 미정의 → Outbox 없음)."
  def skip_operation(id, actor_id),
    do: operation_transition(id, "skipped", "operation.skip", actor_id)

  @doc """
  ready/paused → running. AuditLog + operation.started 이벤트(Outbox)를 동일 트랜잭션으로 생성.
  """
  def start_operation(id, actor_id) do
    id
    |> operation_transition_multi("running", "operation.start", actor_id)
    |> Outbox.put_event(:event, fn %{transition: op} ->
      %{
        event_type: "operation.started",
        aggregate_type: "operation",
        aggregate_id: op.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          operation_id: op.id,
          work_order_id: op.work_order_id,
          process_id: op.process_id,
          started_at: op.started_at,
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  @doc """
  running/paused → completed. AuditLog + operation.completed 이벤트(Outbox)를 동일 트랜잭션으로 생성.
  """
  def complete_operation(id, actor_id) do
    id
    |> operation_transition_multi("completed", "operation.complete", actor_id)
    |> Outbox.put_event(:event, fn %{transition: op} ->
      %{
        event_type: "operation.completed",
        aggregate_type: "operation",
        aggregate_id: op.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          operation_id: op.id,
          work_order_id: op.work_order_id,
          process_id: op.process_id,
          completed_at: op.completed_at,
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  # Outbox 없는 단순 전이(ready/pause/skip) 공통 실행.
  defp operation_transition(id, to_status, action, actor_id) do
    id
    |> operation_transition_multi(to_status, action, actor_id)
    |> Repo.transaction()
    |> normalize_result(:transition)
  end

  # Operation 전이 Multi 골격: 로드 → 전이 update → AuditLog.
  defp operation_transition_multi(id, to_status, action, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load_operation(repo, id) end)
    |> Multi.update(:transition, fn %{load: op} ->
      Operation.transition_changeset(op, to_status)
    end)
    |> Audit.put_log(:audit, fn %{load: before_op, transition: after_op} ->
      %{
        actor_id: actor_id,
        action: action,
        resource_type: "operation",
        resource_id: after_op.id,
        before: %{status: before_op.status},
        after: %{
          status: after_op.status,
          started_at: after_op.started_at,
          completed_at: after_op.completed_at
        }
      }
    end)
  end

  defp load_operation(repo, id) do
    case repo.get(Operation, id) do
      nil -> {:error, :not_found}
      op -> {:ok, op}
    end
  end

  defp operation_snapshot(%Operation{} = op) do
    %{
      work_order_id: op.work_order_id,
      process_id: op.process_id,
      sequence: op.sequence,
      status: op.status
    }
  end

  # ════════════════════════════════════════════════════════════════════
  # ProductionResult (공정 실적) — append-only, AuditLog (Outbox 없음)
  # ════════════════════════════════════════════════════════════════════

  @doc """
  공정 id 목록 → 각 공정의 최신 Operation status 맵(%{process_id => status}).

  공정별로 inserted_at 최신 1건의 status 만 취한다(Postgres `distinct on`).
  빈 목록이거나 Operation 이 없는 공정은 결과에서 제외된다(호출부에서 nil 처리). 읽기 전용.
  """
  def latest_operation_status_by_process(process_ids) when is_list(process_ids) do
    ids = Enum.uniq(process_ids)

    if ids == [] do
      %{}
    else
      from(o in Operation,
        where: o.process_id in ^ids,
        distinct: o.process_id,
        order_by: [asc: o.process_id, desc: o.inserted_at],
        select: {o.process_id, o.status}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc "특정 공정의 실적 목록(최근순)."
  def list_production_results(operation_id) do
    from(r in ProductionResult,
      where: r.operation_id == ^operation_id,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc "공정 실적 단건 조회. 없으면 nil."
  def get_production_result(id), do: Repo.get(ProductionResult, id)

  @doc """
  공정 실적 생성(append-only). 동일 트랜잭션에서 AuditLog(production_result.create) 1건을 남긴다.
  수정/삭제는 제공하지 않는다(정정은 새 레코드).
  """
  def create_production_result(attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:result, ProductionResult.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{result: r} ->
      %{
        actor_id: actor_id,
        action: "production_result.create",
        resource_type: "production_result",
        resource_id: r.id,
        before: nil,
        after: %{
          operation_id: r.operation_id,
          worker_id: r.worker_id,
          equipment_id: r.equipment_id,
          good_quantity: decimal_to_string(r.good_quantity),
          defect_quantity: decimal_to_string(r.defect_quantity),
          started_at: r.started_at,
          ended_at: r.ended_at
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:result)
  end

  # ════════════════════════════════════════════════════════════════════
  # DefectRecord (불량 기록) — append-only, AuditLog + Outbox(defect.recorded)
  # ════════════════════════════════════════════════════════════════════

  @doc "특정 실적의 불량 기록 목록."
  def list_defect_records(production_result_id) do
    from(d in DefectRecord, where: d.production_result_id == ^production_result_id)
    |> Repo.all()
  end

  @doc """
  불량 기록(append-only). 동일 트랜잭션에서 AuditLog + defect.recorded 이벤트(Outbox)를 생성한다.
  """
  def record_defect(attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:defect, DefectRecord.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{defect: d} ->
      %{
        actor_id: actor_id,
        action: "defect.record",
        resource_type: "defect_record",
        resource_id: d.id,
        before: nil,
        after: %{
          production_result_id: d.production_result_id,
          defect_code: d.defect_code,
          quantity: decimal_to_string(d.quantity),
          note: d.note
        }
      }
    end)
    |> Outbox.put_event(:event, fn %{defect: d} ->
      %{
        event_type: "defect.recorded",
        aggregate_type: "defect_record",
        aggregate_id: d.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          defect_record_id: d.id,
          production_result_id: d.production_result_id,
          defect_code: d.defect_code,
          quantity: Decimal.to_string(d.quantity),
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:defect)
  end

  defp fetch(schema_mod, id) do
    case Repo.get(schema_mod, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end
end
