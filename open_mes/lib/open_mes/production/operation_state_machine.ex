defmodule OpenMes.Production.OperationStateMachine do
  @moduledoc """
  공정(Operation) 상태 머신 — 순수 함수 모듈(DB 의존 없음).

  허용 전이표(docs/domain-model.md, 설계 §1.4):

      pending     → ready, skipped
      ready       → running, skipped
      running     → paused, completed
      paused      → running, completed
      completed   → (종료 상태, 전이 불가)
      skipped     → (종료 상태, 전이 불가)

  주 흐름은 pending → ready → running → completed 이며, skipped 는 미실행 종료다.
  completed/skipped 는 종료 상태로 어떤 전이도 불가하다.
  이 표에 없는 전이는 전부 거부한다(임의 전이 추가 금지).

  WorkOrderStateMachine 와 동형 시그니처: statuses/0, can_transition?/2, allowed_from/1.
  """

  @transitions %{
    "pending" => ["ready", "skipped"],
    "ready" => ["running", "skipped"],
    "running" => ["paused", "completed"],
    "paused" => ["running", "completed"],
    "completed" => [],
    "skipped" => []
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
