defmodule OpenMes.Ingest.Sink.NoopSink do
  @moduledoc """
  DomainSink 의 기본 구현. 아무 동작도 하지 않는다. 설계 §6.3.

  MVP 기본값이다. 텔레메트리는 hypertable 에 적재만 되고 코어 도메인으로는
  아무것도 흘러가지 않는다. 이것이 §0-B "텔레메트리는 도메인과 분리" 경계를
  코드 레벨에서 보장한다(코어 무의존).
  """
  @behaviour OpenMes.Ingest.Sink.DomainSink

  @impl true
  def handle_measurements(_rows), do: :ok
end
