defmodule OpenMes.Ingest.DeadLetterTest do
  @moduledoc """
  DeadLetter 격리 단위 테스트(설계 §5).
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Ingest.DeadLetter
  alias OpenMes.Ingest.DeadLetterRecord

  test "오염 메시지를 원본 그대로 격리한다" do
    raw = %{"equipment_id" => "EQP-01", "value" => 1.0}
    assert :ok = DeadLetter.capture(raw, "value_missing", "device:test-token")

    [record] = Repo.all(DeadLetterRecord)
    assert record.reason == "value_missing"
    assert record.source == "device:test-token"
    assert record.raw_payload == raw
  end

  test "map 이 아닌 원본도 래핑해 보존한다" do
    assert :ok = DeadLetter.capture("garbage", "not_a_map")
    [record] = Repo.all(DeadLetterRecord)
    assert record.reason == "not_a_map"
    assert is_map(record.raw_payload)
  end

  test "배치 일괄 격리" do
    rows = [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}]
    assert :ok = DeadLetter.capture_batch(rows, "batch_insert_failed")
    assert Repo.aggregate(DeadLetterRecord, :count) == 3
  end
end
