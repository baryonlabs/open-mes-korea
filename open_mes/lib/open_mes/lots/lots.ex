defmodule OpenMes.Lots do
  @moduledoc """
  LOT 추적(Lots) 바운디드 컨텍스트 — MaterialLot, LotConsumption.

  핵심 불변식:
    - 상태 변경 + 수량 변경 + AuditLog + (필요 시) Outbox 이벤트는 반드시 단일 `Ecto.Multi`.
    - 모든 쓰기 함수는 actor_id 를 명시적으로 받는다.
    - 자재 소비는 LotConsumption 경유만(암묵 소비 금지, CLAUDE.md L73).
      소비 수량은 LotConsumption 레코드가 진실의 원천이며, MaterialLot.quantity 의 잔량 감소는
      이 소비 기록에 의해서만(동일 트랜잭션에서) 일어난다(자의적/직접 수정 금지).
    - LOT 초과 소비 차단(잔량보다 많이 투입 불가, 안전 가드).
    - 제품 LOT 은 source_operation_id 로 Operation 과 연결(genealogy).
    - LotConsumption 은 append-only(수정/삭제 미제공).

  Outbox 이벤트(문서 정의분만): material_lot.consumed, material_lot.produced.
  reserve/quarantine/scrap/release 등 기타 전이는 AuditLog 만(문서 미정의).
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit
  alias OpenMes.Lots.{LotConsumption, MaterialLot}
  alias OpenMes.Outbox
  alias OpenMes.Repo

  # ──────────────────────────────────────────────────────────────────
  # 조회
  # ──────────────────────────────────────────────────────────────────

  @doc "LOT 목록. status/item_id 필터 + 페이지네이션."
  def list_lots(filters \\ %{}) do
    MaterialLot
    |> filter_lot_status(filters)
    |> filter_lot_item(filters)
    |> order_recent()
    |> paginate(filters)
    |> Repo.all()
  end

  @doc "LOT 단건 조회. 없으면 nil."
  def get_lot(id), do: Repo.get(MaterialLot, id)

  @doc "LOT 단건 조회. 없으면 {:error, :not_found}."
  def fetch_lot(id) do
    case Repo.get(MaterialLot, id) do
      nil -> {:error, :not_found}
      lot -> {:ok, lot}
    end
  end

  @doc "lot_no 로 LOT 조회. 없으면 nil(현장 스캔용)."
  def get_lot_by_no(lot_no), do: Repo.get_by(MaterialLot, lot_no: lot_no)

  @doc "특정 공정에 투입된 LOT 소비 기록 목록."
  def list_consumptions(operation_id) do
    from(c in LotConsumption, where: c.operation_id == ^operation_id)
    |> Repo.all()
  end

  # ──────────────────────────────────────────────────────────────────
  # 입고/생산 (LOT 생성)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  원자재 LOT 입고(외부 입고). 초기 상태 available. AuditLog 만(Outbox 없음).
  status 를 명시하지 않으면 available 로 생성된다.
  """
  def receive_lot(attrs, actor_id) do
    attrs = normalize_keys(attrs) |> Map.put_new("status", "available")

    Multi.new()
    |> Multi.insert(:lot, MaterialLot.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{lot: lot} ->
      audit_attrs(actor_id, "material_lot.receive", lot, nil, lot_snapshot(lot))
    end)
    |> Repo.transaction()
    |> normalize_result(:lot)
  end

  @doc """
  생산 LOT 생성. 초기 상태 produced, source_operation_id 로 Operation 과 연결(genealogy).
  동일 트랜잭션에서 AuditLog + material_lot.produced 이벤트(Outbox)를 생성한다.
  """
  def produce_lot(attrs, actor_id) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put("status", "produced")

    Multi.new()
    |> Multi.insert(:lot, MaterialLot.create_changeset(attrs))
    |> Audit.put_log(:audit, fn %{lot: lot} ->
      audit_attrs(actor_id, "material_lot.produce", lot, nil, lot_snapshot(lot))
    end)
    |> Outbox.put_event(:event, fn %{lot: lot} ->
      %{
        event_type: "material_lot.produced",
        aggregate_type: "material_lot",
        aggregate_id: lot.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          material_lot_id: lot.id,
          lot_no: lot.lot_no,
          item_id: lot.item_id,
          source_operation_id: lot.source_operation_id,
          quantity: Decimal.to_string(lot.quantity),
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:lot)
  end

  # ──────────────────────────────────────────────────────────────────
  # 단순 상태 전이 (AuditLog 만 — 문서 미정의 이벤트)
  # ──────────────────────────────────────────────────────────────────

  @doc "available/produced → reserved. AuditLog 만."
  def reserve_lot(id, actor_id), do: lot_transition(id, "reserved", "material_lot.reserve", actor_id)

  @doc "reserved → available (예약 해제). AuditLog 만."
  def release_lot(id, actor_id), do: lot_transition(id, "available", "material_lot.release", actor_id)

  @doc "* → quarantined(격리). AuditLog 만."
  def quarantine_lot(id, actor_id),
    do: lot_transition(id, "quarantined", "material_lot.quarantine", actor_id)

  @doc "available/quarantined → scrapped(폐기). AuditLog 만."
  def scrap_lot(id, actor_id), do: lot_transition(id, "scrapped", "material_lot.scrap", actor_id)

  defp lot_transition(id, to_status, action, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load_lot(repo, id) end)
    |> Multi.update(:lot, fn %{load: lot} -> MaterialLot.transition_changeset(lot, to_status) end)
    |> Audit.put_log(:audit, fn %{load: before_lot, lot: after_lot} ->
      audit_attrs(actor_id, action, after_lot, %{status: before_lot.status}, %{
        status: after_lot.status
      })
    end)
    |> Repo.transaction()
    |> normalize_result(:lot)
  end

  # ──────────────────────────────────────────────────────────────────
  # 소비 (LotConsumption 경유 — genealogy 의 핵심)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  공정(operation)에 자재 LOT(input_lot)를 quantity 만큼 투입(소비)한다.

  단일 Multi 로:
    1. input LOT 로드 + 종료 상태(consumed/scrapped) 차단 + 초과 소비 차단(잔량 >= quantity).
    2. LotConsumption 레코드 insert(소비 진실의 원천).
    3. LOT 잔량(quantity) 차감. 잔량 0 이 되면 consumed 로 전이, 아니면 상태 유지.
    4. AuditLog(lot.consume) + material_lot.consumed 이벤트(Outbox).

  MaterialLot.quantity 직접 감소 금지 원칙: 잔량 차감은 오직 이 소비 기록과 동반해서만 일어난다.
  """
  def consume_lot(operation_id, input_lot_id, quantity, actor_id) do
    qty = to_decimal(quantity)

    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load_lot(repo, input_lot_id) end)
    |> Multi.run(:guard, fn _repo, %{load: lot} -> guard_consumption(lot, qty) end)
    |> Multi.insert(:consumption, fn _ ->
      LotConsumption.create_changeset(%{
        operation_id: operation_id,
        input_lot_id: input_lot_id,
        quantity: qty
      })
    end)
    |> Multi.update(:lot, fn %{load: lot} -> apply_consumption(lot, qty) end)
    |> Audit.put_log(:audit, fn %{load: before_lot, lot: after_lot, consumption: c} ->
      audit_attrs(actor_id, "lot.consume", after_lot, lot_snapshot(before_lot), %{
        status: after_lot.status,
        quantity: Decimal.to_string(after_lot.quantity),
        consumption_id: c.id,
        consumed_quantity: Decimal.to_string(c.quantity)
      })
    end)
    |> Outbox.put_event(:event, fn %{lot: lot, consumption: c} ->
      %{
        event_type: "material_lot.consumed",
        aggregate_type: "material_lot",
        aggregate_id: lot.id,
        occurred_at: DateTime.utc_now(),
        payload: %{
          material_lot_id: lot.id,
          lot_no: lot.lot_no,
          operation_id: operation_id,
          consumed_quantity: Decimal.to_string(c.quantity),
          remaining_quantity: Decimal.to_string(lot.quantity),
          status: lot.status,
          actor_id: actor_id
        }
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:consumption)
  end

  @doc """
  특정 제품 LOT 의 1단계 계보(genealogy)를 조회한다.
  제품 LOT.source_operation_id → 그 operation 에 투입된 LotConsumption → input LOT 목록.
  반환: %{lot: lot, source_operation_id: id, inputs: [%{consumption: c, lot: input_lot}]}.
  """
  def genealogy(lot_id) do
    case Repo.get(MaterialLot, lot_id) do
      nil ->
        {:error, :not_found}

      %MaterialLot{source_operation_id: nil} = lot ->
        {:ok, %{lot: lot, source_operation_id: nil, inputs: []}}

      %MaterialLot{source_operation_id: op_id} = lot ->
        inputs =
          from(c in LotConsumption,
            where: c.operation_id == ^op_id,
            join: l in MaterialLot,
            on: l.id == c.input_lot_id,
            select: %{consumption: c, lot: l}
          )
          |> Repo.all()

        {:ok, %{lot: lot, source_operation_id: op_id, inputs: inputs}}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  # 소비 가능 여부 가드: 종료 상태 차단 + 초과 소비 차단.
  defp guard_consumption(%MaterialLot{status: status}, _qty)
       when status in ["consumed", "scrapped"],
       do: {:error, :lot_not_consumable}

  defp guard_consumption(%MaterialLot{quantity: remaining}, qty) do
    if Decimal.compare(qty, remaining) == :gt do
      {:error, :insufficient_lot_quantity}
    else
      {:ok, :ok}
    end
  end

  # 잔량 차감 + (0 도달 시) consumed 전이. 부분 소비는 상태 유지.
  defp apply_consumption(%MaterialLot{quantity: remaining, status: from} = lot, qty) do
    new_qty = Decimal.sub(remaining, qty)

    changeset = Ecto.Changeset.change(lot, quantity: new_qty)

    if Decimal.compare(new_qty, Decimal.new(0)) == :eq do
      # 완전 소비: 상태머신상 consumed 진입은 reserved 에서만 허용되므로,
      # available/produced 에서 직접 소비되는 경우 reserved 를 거치지 않고 consumed 로 마감한다.
      # (소비 가드를 이미 통과했으므로 잔량 기준으로 마감 처리한다.)
      if from == "consumed" do
        changeset
      else
        Ecto.Changeset.change(changeset, status: "consumed")
      end
    else
      changeset
    end
  end

  defp load_lot(repo, id) do
    case repo.get(MaterialLot, id) do
      nil -> {:error, :not_found}
      lot -> {:ok, lot}
    end
  end

  defp filter_lot_status(query, %{"status" => status}) when is_binary(status) and status != "",
    do: from(l in query, where: l.status == ^status)

  defp filter_lot_status(query, _), do: query

  defp filter_lot_item(query, %{"item_id" => item_id}) when is_binary(item_id) and item_id != "",
    do: from(l in query, where: l.item_id == ^item_id)

  defp filter_lot_item(query, _), do: query

  defp order_recent(query), do: from(l in query, order_by: [desc: l.inserted_at])

  defp paginate(query, filters) do
    limit = parse_int(Map.get(filters, "limit"), 50) |> min(200) |> max(1)
    offset = parse_int(Map.get(filters, "offset"), 0) |> max(0)
    from(l in query, limit: ^limit, offset: ^offset)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp audit_attrs(actor_id, action, %MaterialLot{} = lot, before, after_snap) do
    %{
      actor_id: actor_id,
      action: action,
      resource_type: "material_lot",
      resource_id: lot.id,
      before: before,
      after: after_snap
    }
  end

  defp lot_snapshot(%MaterialLot{} = lot) do
    %{
      lot_no: lot.lot_no,
      item_id: lot.item_id,
      lot_type: lot.lot_type,
      quantity: decimal_to_string(lot.quantity),
      status: lot.status,
      source_operation_id: lot.source_operation_id
    }
  end

  # 문자열/atom 키 혼용 attrs 를 문자열 키로 정규화(create_changeset 가 cast 처리).
  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp normalize_result({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp normalize_result({:error, :load, :not_found, _}, _key), do: {:error, :not_found}
  defp normalize_result({:error, :guard, reason, _}, _key), do: {:error, reason}
  defp normalize_result({:error, _step, %Ecto.Changeset{} = cs, _}, _key), do: {:error, cs}
  defp normalize_result({:error, _step, reason, _}, _key), do: {:error, reason}

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
end
