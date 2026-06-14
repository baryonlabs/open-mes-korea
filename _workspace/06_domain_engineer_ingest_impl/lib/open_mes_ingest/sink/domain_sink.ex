defmodule OpenMes.Ingest.Sink.DomainSink do
  @moduledoc """
  텔레메트리 → 코어 도메인 신호 변환 **behaviour 계약**. 설계 §6.2.

  수집 파이프라인이 코어 도메인과 만나는 **유일한 추상 경계**다.
  확장은 코어 내부 모듈/스키마를 직접 호출하지 않고, 이 behaviour 구현체를 통해서만
  도메인에 영향을 준다(의존 방향: 확장 → 코어 단방향 유지).

  적재된 measurement row 배치를 받아, 도메인적으로 의미 있는 신호(임계치 초과 등)를
  판단해 코어로 흘려보낼 수 있다. 어떤 구현체를 쓸지는 config 로 선택한다:

      config :open_mes, OpenMes.Ingest, sink: OpenMes.Ingest.Sink.NoopSink

  - 기본값은 `NoopSink`(아무것도 안 함) — 텔레메트리는 적재만 되고 코어로 흘러가지 않는다.
    이것이 "텔레메트리는 도메인과 분리"(설계 §0-B) 경계를 코드로 보장한다.
  - 도메인 이벤트 연계가 필요하면 `OutboxSink` 로 교체(설계 §6.3, §8.4).
  """

  @doc """
  검증·적재된 measurement row 배치를 후처리한다.
  도메인 이벤트 발행 등 코어 연계를 여기서 수행한다. 부작용은 구현체 책임.
  """
  @callback handle_measurements([map()]) :: :ok
end
