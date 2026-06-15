defmodule OpenMes.Media.StateMachine do
  @moduledoc """
  멀티미디어 자산 처리상태 머신 — 순수 함수 모듈(DB 의존 없음).

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §5.2.

  허용 전이표(이 표에 없는 전이는 전부 거부 — 임의 전이 추가 절대 금지):

      detected        → uploading, duplicate
      uploading       → stored, transfer_failed, duplicate
      stored          → feature_extracted      # (예약, EXT-3) 자리만 둠. 이번 범위에서 호출 경로 없음.
      transfer_failed → uploading, dead         # 재시도하거나, 재시도 소진 시 영구 실패
      stored          → (종료에 준함, feature_extracted 외 전이 없음)
      dead            → (종료 상태)
      duplicate       → (종료 상태)
      feature_extracted → (종료 상태)

  핵심 원칙(EXT-1 멱등 전이 버그 교훈):
    - 본 모듈은 "이 전이가 허용되는가"만 판정한다(순수 함수).
    - 실제 전이 실행은 컨텍스트가 조건부 UPDATE(`WHERE state = <expected_from>`)로 선점하여
      다중 워커/재시작에 안전하게 처리한다(MediaAsset.claim_query/2 참조).
    - 동일 상태로의 전이(no-op)는 허용 전이표에 자기 자신이 없으므로 항상 false 다.
  """

  # 처리상태 전이 화이트리스트. feature_extracted 는 EXT-3 예약(stored 에서 자리만 둠).
  @transitions %{
    "detected" => ["uploading", "duplicate"],
    "uploading" => ["stored", "transfer_failed", "duplicate"],
    "stored" => ["feature_extracted"],
    "transfer_failed" => ["uploading", "dead"],
    "dead" => [],
    "duplicate" => [],
    "feature_extracted" => []
  }

  @states Map.keys(@transitions)

  @doc "정의된 모든 처리상태 값 목록을 반환한다."
  def states, do: @states

  @doc """
  `from` 상태에서 `to` 상태로의 전이가 허용 전이표에 있는지 반환한다.
  정의되지 않은 상태/전이는 모두 false(동일 상태 전이 포함).
  """
  def can_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "`from` 상태에서 전이 가능한 상태 목록을 반환한다."
  def allowed_from(from), do: Map.get(@transitions, from, [])
end
