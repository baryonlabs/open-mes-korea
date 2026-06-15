defmodule OpenMes.Ingest.Sink.NoopSinkTest do
  @moduledoc """
  NoopSink 테스트(설계 §6.3): 기본 sink 는 코어로 아무것도 흘리지 않는다.
  DomainSink behaviour 를 구현하며 :ok 만 반환함을 확인한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Ingest.Sink.NoopSink

  test "DomainSink behaviour 를 구현한다" do
    behaviours = NoopSink.module_info(:attributes)[:behaviour] || []
    assert OpenMes.Ingest.Sink.DomainSink in behaviours
  end

  test "어떤 measurement 배치를 받아도 :ok 만 반환(부작용 없음)" do
    rows = [%{equipment_id: "EQP-01", value: 1.0}, %{equipment_id: "EQP-02", value: 2.0}]
    assert NoopSink.handle_measurements(rows) == :ok
    assert NoopSink.handle_measurements([]) == :ok
  end
end
