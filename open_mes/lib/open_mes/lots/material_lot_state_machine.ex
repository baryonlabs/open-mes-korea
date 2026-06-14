defmodule OpenMes.Lots.MaterialLotStateMachine do
  @moduledoc """
  자재/제품 LOT(MaterialLot) 상태 머신 — 순수 함수 모듈(DB 의존 없음).

  허용 전이표(docs/domain-model.md, 설계 §1.4):

      available    → reserved, quarantined, scrapped
      reserved     → consumed, available, quarantined
      quarantined  → available, scrapped
      produced     → available, reserved, quarantined
      consumed     → (종료 상태, 전이 불가)
      scrapped     → (종료 상태, 전이 불가)

  초기 상태:
    - 입고 원자재 LOT: available
    - 생산 LOT: produced (이후 available/reserved 로 가용화)
  소비(consumed)는 LotConsumption 기록과 동반된다(컨텍스트에서 단일 Multi).
  consumed/scrapped 는 종료 상태로 어떤 전이도 불가하다.
  이 표에 없는 전이는 전부 거부한다(임의 전이 추가 금지).

  WorkOrderStateMachine 와 동형 시그니처: statuses/0, can_transition?/2, allowed_from/1.
  """

  @transitions %{
    "available" => ["reserved", "quarantined", "scrapped"],
    "reserved" => ["consumed", "available", "quarantined"],
    "quarantined" => ["available", "scrapped"],
    "produced" => ["available", "reserved", "quarantined"],
    "consumed" => [],
    "scrapped" => []
  }

  @statuses Map.keys(@transitions)

  @doc "정의된 모든 상태값 목록을 반환한다."
  def statuses, do: @statuses

  @doc """
  `from` 상태에서 `to` 상태로의 전이가 허용되는지 반환한다.
  정의되지 않은 상태/전이는 모두 false.
  """
  def can_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "`from` 상태에서 전이 가능한 상태 목록을 반환한다."
  def allowed_from(from), do: Map.get(@transitions, from, [])
end
