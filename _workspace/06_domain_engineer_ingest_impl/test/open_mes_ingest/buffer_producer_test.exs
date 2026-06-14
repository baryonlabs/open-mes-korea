defmodule OpenMes.Ingest.BufferProducerTest do
  @moduledoc """
  BufferProducer 백프레셔 단위 테스트(설계 §3.4, §7.2).

  producer 를 단독 GenStage 로 기동해 큐 상한 동작을 검증한다.
  (Broadway 전체 토폴로지 없이 producer 의 push/큐 로직만 격리 테스트.)
  """
  use ExUnit.Case, async: true

  alias OpenMes.Ingest.BufferProducer

  setup do
    # 작은 상한(3)으로 기동해 포화 동작을 빠르게 검증.
    {:ok, pid} = GenStage.start_link(BufferProducer, max_queue_len: 3)
    %{producer: pid}
  end

  test "demand 가 없으면 큐에 쌓인다", %{producer: pid} do
    assert :ok = BufferProducer.push(pid, %{"a" => 1})
    assert :ok = BufferProducer.push(pid, %{"a" => 2})
    assert BufferProducer.queue_len(pid) == 2
  end

  test "큐 상한 초과 시 {:error, :busy} 를 반환한다(백프레셔)", %{producer: pid} do
    assert :ok = BufferProducer.push(pid, %{"n" => 1})
    assert :ok = BufferProducer.push(pid, %{"n" => 2})
    assert :ok = BufferProducer.push(pid, %{"n" => 3})
    # 상한(3) 도달 → 다음 push 거부
    assert {:error, :busy} = BufferProducer.push(pid, %{"n" => 4})
    assert BufferProducer.queue_len(pid) == 3
  end

  test "소비자(consumer)가 demand 를 보내면 큐가 비워지고 다시 적재 가능", %{producer: pid} do
    Enum.each(1..3, fn n -> :ok = BufferProducer.push(pid, %{"n" => n}) end)
    assert {:error, :busy} = BufferProducer.push(pid, %{"n" => 99})

    # 더미 consumer 를 붙여 demand 를 발생시킨다 → producer 큐가 디스패치된다.
    {:ok, _consumer} =
      GenStage.start_link(OpenMes.Ingest.BufferProducerTest.DummyConsumer, pid)

    # 디스패치가 일어날 때까지 잠깐 대기 후 큐가 줄었는지 확인.
    Process.sleep(50)
    assert BufferProducer.queue_len(pid) < 3
    # 다시 적재 가능
    assert :ok = BufferProducer.push(pid, %{"n" => 100})
  end

  defmodule DummyConsumer do
    @moduledoc false
    use GenStage

    def init(producer) do
      {:consumer, :ok, subscribe_to: [{producer, max_demand: 10, min_demand: 0}]}
    end

    def handle_events(_events, _from, state) do
      {:noreply, [], state}
    end
  end
end
