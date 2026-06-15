defmodule OpenMes.Lots.Reports do
  @moduledoc """
  LOT/재고 조회(G5) 읽기 전용 집계 모듈.

  쓰기 없음(AuditLog 무관). 품목별 재고 흐름(입고/생산/소비)을 서버측 쿼리로 산출한다.

  재고 흐름 정의(MVP, MaterialLot 상태 기반):
    - 입고/생산 수량은 LOT 의 현재 잔량(quantity)을 상태별로 합산해 근사한다.
    - 소비 수량은 LotConsumption 합계(자재 투입 진실의 원천)로 산출한다.

  방어: 빈 데이터에서 0/[] 반환, 0 나눗셈 없음(단순 합계).
  """
  import Ecto.Query, only: [from: 2]

  alias OpenMes.Lots.{LotConsumption, MaterialLot}
  alias OpenMes.Repo

  # 재고로 잡히는(가용/예약/생산 직후) 상태. consumed/scrapped 는 잔량 0 또는 폐기라 제외.
  @on_hand_statuses ~w(available reserved produced quarantined)

  @doc """
  LOT 상태별 건수 + 잔량 합계 집계.
  반환: [%{status, count, quantity: Decimal}] (상태명 순). 비어 있으면 [].
  """
  def lots_by_status do
    from(l in MaterialLot,
      group_by: l.status,
      order_by: l.status,
      select: %{status: l.status, count: count(l.id), quantity: coalesce(sum(l.quantity), 0)}
    )
    |> Repo.all()
    |> Enum.map(fn row -> %{row | quantity: to_decimal(row.quantity)} end)
  end

  @doc """
  품목별 재고 흐름 집계.

  각 품목에 대해:
    - lot_count        : 해당 품목 LOT 총 건수
    - on_hand_quantity : 현재 보유 잔량(가용/예약/생산/격리 상태 LOT quantity 합)
    - consumed_quantity: 해당 품목 LOT 이 공정에 투입된 누적 소비량(LotConsumption 합)
    - produced_quantity: 생산 LOT(source_operation_id != nil) 잔량 합(생산 유입 근사)

  반환: [%{item_id, lot_count, on_hand_quantity, consumed_quantity, produced_quantity}]
  (LOT 건수 많은 순). 데이터 없으면 [].
  """
  def inventory_flow_by_item do
    on_hand = on_hand_by_item()
    produced = produced_by_item()
    consumed = consumed_by_item()
    counts = lot_count_by_item()

    counts
    |> Enum.map(fn {item_id, lot_count} ->
      %{
        item_id: item_id,
        lot_count: lot_count,
        on_hand_quantity: Map.get(on_hand, item_id, Decimal.new(0)),
        produced_quantity: Map.get(produced, item_id, Decimal.new(0)),
        consumed_quantity: Map.get(consumed, item_id, Decimal.new(0))
      }
    end)
    |> Enum.sort_by(& &1.lot_count, :desc)
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 쿼리 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp lot_count_by_item do
    from(l in MaterialLot, group_by: l.item_id, select: {l.item_id, count(l.id)})
    |> Repo.all()
  end

  defp on_hand_by_item do
    from(l in MaterialLot,
      where: l.status in @on_hand_statuses,
      group_by: l.item_id,
      select: {l.item_id, coalesce(sum(l.quantity), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, q} -> {id, to_decimal(q)} end)
  end

  defp produced_by_item do
    from(l in MaterialLot,
      where: not is_nil(l.source_operation_id),
      group_by: l.item_id,
      select: {l.item_id, coalesce(sum(l.quantity), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, q} -> {id, to_decimal(q)} end)
  end

  # 품목별 소비량: LotConsumption → input_lot 의 item_id 로 묶는다.
  defp consumed_by_item do
    from(c in LotConsumption,
      join: l in MaterialLot,
      on: l.id == c.input_lot_id,
      group_by: l.item_id,
      select: {l.item_id, coalesce(sum(c.quantity), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, q} -> {id, to_decimal(q)} end)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: Decimal.new(0)
end
