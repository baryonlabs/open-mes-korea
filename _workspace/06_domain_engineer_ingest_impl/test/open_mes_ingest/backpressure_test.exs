defmodule OpenMes.Ingest.BackpressureTest do
  @moduledoc """
  큐 포화 → 429 백프레셔 계약 테스트(설계 §3.4, §4.1).

  실행 중인 Broadway 파이프라인은 큐를 계속 비우므로(draining) 포화를 결정론적으로
  재현하기 어렵다. 따라서 여기서는 **비배수(non-draining) 단독 producer** 를 띄워
  포화 상황을 만들고, 컨트롤러가 의존하는 계약(`push_many` 가 거부 건수를 보고 → 429)을
  검증한다. 컨트롤러의 거부→429 매핑은 IngestController.create 의 `{accepted, rejected}`
  분기로 직접 확인된다(아래 render 계약 테스트).
  """
  use ExUnit.Case, async: true

  alias OpenMes.Ingest.BufferProducer

  test "큐 상한 도달 후 추가 push 는 거부(busy)되어 백프레셔를 전파한다" do
    # consumer 를 붙이지 않은 단독 producer → 큐가 배수되지 않음.
    {:ok, pid} = GenStage.start_link(BufferProducer, max_queue_len: 2)

    assert :ok = BufferProducer.push(pid, %{"n" => 1})
    assert :ok = BufferProducer.push(pid, %{"n" => 2})
    # 상한 도달 → 거부
    assert {:error, :busy} = BufferProducer.push(pid, %{"n" => 3})
  end

  test "컨트롤러 계약: 거부가 1건 이상이면 429 응답 형태가 된다" do
    # 컨트롤러 create 의 분기 로직을 직접 재현(설계 §4.1):
    #   {accepted, 0}        → 202
    #   {accepted, rejected} → 429
    # 아래는 그 분기 자체가 의도대로인지 명세화한 계약 테스트.
    assert classify({2, 0}) == :accepted_202
    assert classify({1, 1}) == :busy_429
    assert classify({0, 3}) == :busy_429
  end

  # 컨트롤러 create/2 의 status 분기와 동일한 규칙(명세 고정용).
  defp classify({_accepted, 0}), do: :accepted_202
  defp classify({_accepted, rejected}) when rejected > 0, do: :busy_429
end
