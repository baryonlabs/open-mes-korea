defmodule OpenMes.Production.WorkOrderStateMachine do
  @moduledoc """
  작업지시 상태 머신 — 순수 함수 모듈(DB 의존 없음).

  허용 전이표(docs/domain-model.md, CLAUDE.md L35 기준):

      draft       → released, cancelled
      released    → in_progress, cancelled
      in_progress → completed, cancelled
      completed   → (종료 상태, 전이 불가)
      cancelled   → (종료 상태, 전이 불가)

  주 흐름은 draft → released → in_progress → completed 이며,
  cancelled 는 진행 중 어느 상태에서도 가능하다(현장에서 작업지시 취소는 흔함).
  completed/cancelled 는 종료 상태로 어떤 전이도 불가하다.
  이 표에 없는 전이는 전부 거부한다(임의 전이 추가 절대 금지).
  """

  @transitions %{
    "draft" => ["released", "cancelled"],
    "released" => ["in_progress", "cancelled"],
    "in_progress" => ["completed", "cancelled"],
    "completed" => [],
    "cancelled" => []
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
