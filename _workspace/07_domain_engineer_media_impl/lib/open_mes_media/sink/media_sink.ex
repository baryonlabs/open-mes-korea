defmodule OpenMes.Media.Sink.MediaSink do
  @moduledoc """
  stored 후처리 계약(behaviour). (EXT-2 §6.2)

  EXT-2 가 코어/EXT-3 와 만나는 **추상 경계**다. 의존 방향(확장→코어)을 지키기 위해,
  멀티미디어 그 자체는 코어에 닿지 않고 도메인 의미 사건만 이 경계를 통해 흐른다.

    - 기본(NoopSink): 아무 동작 안 함. MVP 기본값. 적재+인덱싱만 되고 코어/EXT-3 로
      아무것도 안 흘러간다(§0-C 텔레메트리 경계를 코드로 보장).
    - 후속(EXT-3): 특징 추출(소음 dB/주파수 피크) → equipment_measurements 합류,
      또는 도메인 신호(영상 수집완료→검사 트리거)를 코어 `OpenMes.Outbox.emit` 으로 발행.

  TransferWorker 가 `stored` 전이 직후 `configured_sink().handle_stored(asset)` 를 호출한다.
  sink 는 부수효과만 책임지며, 실패하더라도 stored 확정(=원본 보존 종료 가능 시점)을
  되돌리지 않는다(이관은 이미 검증·확정됨).
  """

  @doc """
  stored 확정된 asset 에 대한 후처리.

  반환은 `:ok` 로 통일한다(MVP). 구현체의 실패는 자체적으로 로깅/재시도하되,
  이관 상태(stored)에는 영향을 주지 않는다.
  """
  @callback handle_stored(asset :: OpenMes.Media.MediaAsset.t() | map()) :: :ok
end
