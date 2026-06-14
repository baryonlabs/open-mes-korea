defmodule OpenMes.Media.Sink.NoopSink do
  @moduledoc """
  MediaSink 기본 구현 — 아무 동작도 하지 않는다. MVP 기본값. (EXT-2 §6.2)

  멀티미디어는 object storage 적재 + 인덱싱만 되고 코어/EXT-3 로 아무것도 흘러가지 않는다.
  §0-C 텔레메트리 경계를 코드로 보장하는 구현체.

  EXT-3 도입 시 config 의 `:sink` 를 FeatureExtractSink 로 교체하면 된다.
  코어는 이 behaviour 의 존재조차 모른다(의존 방향 확장→코어 유지).
  """
  @behaviour OpenMes.Media.Sink.MediaSink

  @impl true
  def handle_stored(_asset), do: :ok
end
