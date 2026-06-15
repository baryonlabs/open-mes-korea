defmodule OpenMes.Ingest.FacadeTest do
  @moduledoc """
  Ingest 퍼사드 + config on/off 테스트(설계 §6.1, §7.3).

  코어 비침투 핵심: `enabled?/0` 가 config 플래그를 정확히 반영하고,
  비활성 시 queue_depth 가 0(파이프라인 미기동에도 안전)임을 확인한다.

  async: false — Application.put_env 로 전역 config 를 토글하므로 직렬 실행.
  """
  use ExUnit.Case, async: false

  alias OpenMes.Ingest

  setup do
    original = Application.get_env(:open_mes, OpenMes.Ingest)
    on_exit(fn -> Application.put_env(:open_mes, OpenMes.Ingest, original) end)
    :ok
  end

  test "enabled: false 면 enabled?/0 == false, queue_depth == 0 (코어 영향 0)" do
    Application.put_env(:open_mes, OpenMes.Ingest, enabled: false)
    refute Ingest.enabled?()
    # 파이프라인이 안 떠 있어도 안전하게 0 반환
    assert Ingest.queue_depth() == 0
  end

  test "enabled: true 면 enabled?/0 == true" do
    Application.put_env(:open_mes, OpenMes.Ingest, enabled: true, device_tokens: ["t"])
    assert Ingest.enabled?()
  end

  test "sink 미설정 시 기본값은 NoopSink (텔레메트리 무연계)" do
    Application.put_env(:open_mes, OpenMes.Ingest, enabled: true)
    assert Ingest.configured_sink() == OpenMes.Ingest.Sink.NoopSink
  end

  test "push_many 는 {accepted, rejected} 집계를 반환한다(계약)" do
    # 실제 producer 없이도 계약 형태를 보장하기 위해 비활성 상태에서도
    # 함수 시그니처/집계 규칙이 안정적인지 확인하는 것은 BufferProducer 테스트에서 다룸.
    # 여기서는 빈 리스트의 경계만 확인.
    assert Ingest.push_many([]) == {0, 0}
  end
end
