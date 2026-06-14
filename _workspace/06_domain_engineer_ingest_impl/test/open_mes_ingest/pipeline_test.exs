defmodule OpenMes.Ingest.PipelineTest do
  @moduledoc """
  Broadway 파이프라인 통합 테스트(설계 §7.4).

  `Broadway.test_message/2` 로 실행 중인 파이프라인에 메시지를 흘려보내
  정상 적재 / 오염 dead-letter 격리를 검증한다.

  주의(샌드박스): Broadway processor/batcher 는 별도 프로세스이므로 SQL Sandbox 를
  공유 모드(`shared: true`)로 둔다(async: false). 그래야 파이프라인 프로세스가
  같은 테스트 트랜잭션의 커넥션을 본다.

  전제: 이 테스트는 ingest 파이프라인이 기동된 상태(test 환경 enabled: true)에서 돈다.
  TimescaleDB hypertable 은 일반 INSERT 관점에서 보통 테이블과 동일하게 동작하므로
  insert_all 검증에 특별 처리는 필요 없다(단 테스트 DB 에 마이그레이션이 적용돼 있어야 함).
  """
  use OpenMes.DataCase, async: false

  alias OpenMes.Ingest.{Measurement, DeadLetterRecord}

  setup do
    # 공유 샌드박스: Broadway 프로세스들이 테스트 커넥션을 공유하도록.
    Ecto.Adapters.SQL.Sandbox.mode(OpenMes.Repo, {:shared, self()})
    :ok
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  test "정상 메시지는 equipment_measurements 에 적재된다" do
    raw = %{
      "equipment_id" => "EQP-01",
      "metric_key" => "temperature",
      "value" => 72.4,
      "unit" => "degC",
      "measured_at" => now_iso()
    }

    ref = Broadway.test_message(OpenMes.Ingest.Pipeline, raw)
    # batcher 까지 통과(handle_batch) 확인
    assert_receive {:ack, ^ref, [_successful], []}, 2_000

    rows = Repo.all(Measurement)
    assert Enum.any?(rows, &(&1.equipment_id == "EQP-01" and &1.value == 72.4))
    # 텔레메트리 경로 — AuditLog 없음(설계 §0-B, 정상)
  end

  test "오염 메시지(필수 필드 누락)는 dead-letter 로 격리되고 failed 처리된다" do
    raw = %{"metric_key" => "temperature", "value" => 1.0, "measured_at" => now_iso()}

    ref = Broadway.test_message(OpenMes.Ingest.Pipeline, raw)
    # 검증 실패 → failed 메시지로 ack
    assert_receive {:ack, ^ref, [], [_failed]}, 2_000

    dead = Repo.all(DeadLetterRecord)
    assert Enum.any?(dead, &(&1.reason == "missing:equipment_id"))

    # 오염 메시지는 measurement 로 적재되지 않는다
    assert Repo.aggregate(Measurement, :count) == 0
  end

  test "value/string_value 둘 다 없는 메시지도 dead-letter 격리" do
    raw = %{
      "equipment_id" => "EQP-09",
      "metric_key" => "temperature",
      "measured_at" => now_iso()
    }

    ref = Broadway.test_message(OpenMes.Ingest.Pipeline, raw)
    assert_receive {:ack, ^ref, [], [_failed]}, 2_000

    assert Repo.exists?(
             from d in DeadLetterRecord, where: d.reason == "value_missing"
           )
  end
end
