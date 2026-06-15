defmodule OpenMes.Ingest.Sink.OutboxSink do
  @moduledoc """
  코어 outbox 로 도메인 이벤트를 발행하는 DomainSink 구현(옵션/후속). 설계 §6.3, §8.4.

  ⚠️ MVP 에서는 **스켈레톤만** 둔다. 기본 sink 는 NoopSink 다.

  활성화 전제(설계 §6.3, §8.4):
    1. 발행할 이벤트 타입(예: `equipment.threshold_breached`)이
       docs/system-architecture.md 의 이벤트 목록에 **정식 추가**되어야 한다.
       (01번 설계 결정 승계 — 문서에 없는 이벤트 타입 임의 추가 금지.)
    2. 임계치 규칙(어떤 metric 이 몇이면 이벤트인지)은 도메인/사용자 정의가 필요(현재 미정).
    3. config 에서 sink 를 본 모듈로 교체.

  발행 규칙(qa-auditor 검증 대비):
    - 도메인 이벤트는 반드시 코어 `OpenMes.Outbox` 를 경유한다(동일 트랜잭션 패턴).
    - outbox_events 테이블에 직접 INSERT 하지 않는다.
    - 이것이 확장이 코어에 닿는 **허용된 단방향 호출**의 유일한 통로다(설계 §1.2).
  """
  @behaviour OpenMes.Ingest.Sink.DomainSink


  @impl true
  def handle_measurements(rows) when is_list(rows) do
    # MVP 스켈레톤: 임계치 규칙·이벤트 타입이 미정이므로 발행하지 않는다.
    #
    # 활성화 시 구현 형태(설계 §6.3 — 반드시 코어 Outbox 경유):
    #
    #   alias Ecto.Multi
    #   rows
    #   |> Enum.filter(&threshold_breached?/1)
    #   |> Enum.reduce(Multi.new(), fn row, multi ->
    #     OpenMes.Outbox.put_event(multi, {:evt, row.equipment_id}, fn _ ->
    #       %{
    #         event_type: "equipment.threshold_breached",  # ← 문서 등재 후에만
    #         aggregate_type: "equipment",
    #         aggregate_id: row.equipment_id,
    #         occurred_at: DateTime.utc_now(),
    #         payload: %{metric_key: row.metric_key, value: row.value}
    #       }
    #     end)
    #   end)
    #   |> OpenMes.Repo.transaction()
    #
    # 단 이벤트 타입이 문서에 등재되기 전에는 발행하지 않는다.
    _ = rows
    :ok
  end
end
