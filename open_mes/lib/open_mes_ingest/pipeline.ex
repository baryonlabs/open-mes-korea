defmodule OpenMes.Ingest.Pipeline do
  @moduledoc """
  Broadway 수집 파이프라인. 설계 §3.

  토폴로지:
      [BufferProducer]  ← 브로커리스 내부 큐(GenStage). demand 기반 백프레셔.
            ↓
      [processors]      ← 검증·변환(Validator). 실패 시 dead-letter + Message.failed.
            ↓
      [batchers :timescale] ← TimescaleDB 벌크 insert_all(Loader) + DomainSink 후처리.

  AuditLog 경계(설계 §0-B, §7.3): 텔레메트리 적재 경로에 건건 AuditLog 가 없는 것은
  **정상**이다. append-only hypertable 자체가 이력성을 보장한다. 누락이 아니다.

  오염 데이터 격리(설계 §5): 검증 실패는 즉시 dead-letter 격리 후 Message.failed 로
  재시도 루프를 차단한다(garbage in 은 재시도해도 영원히 실패).
  """
  use Broadway

  alias Broadway.Message
  alias OpenMes.Ingest
  alias OpenMes.Ingest.{Validator, Loader, DeadLetter}

  require Logger

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {OpenMes.Ingest.BufferProducer, []},
        concurrency: 1,
        # producer 가 한 윈도에 내보내는 최대 이벤트 수(메모리 폭주 방지 상한, 설계 §3.4)
        rate_limiting: [allowed_messages: 5_000, interval: 1_000]
      ],
      processors: [
        default: [
          # CPU 바운드 검증 — 코어 수에 비례
          concurrency: System.schedulers_online() * 2,
          # 핵심 백프레셔 노브: processor 당 미처리 상한(설계 §3.4)
          max_demand: 100
        ]
      ],
      batchers: [
        timescale: [
          concurrency: 2,
          # insert_all 한 번에 500행(PostgreSQL 파라미터 한계 내, 설계 §3.4)
          batch_size: 500,
          # 500행 안 차도 1초 후 flush(저빈도에도 데이터 가시성 보장)
          batch_timeout: 1_000
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: raw} = msg, _ctx) do
    case Validator.validate(raw) do
      {:ok, row} ->
        msg
        |> Message.update_data(fn _ -> row end)
        |> Message.put_batcher(:timescale)

      {:error, reason} ->
        # 검증 실패 = 오염 데이터 → dead-letter 격리 후 failed(재시도 안 함, 설계 §5.1).
        DeadLetter.capture(raw, reason)
        Message.failed(msg, reason)
    end
  end

  @impl true
  def handle_batch(:timescale, messages, _batch_info, _ctx) do
    rows = Enum.map(messages, & &1.data)

    case Loader.bulk_insert(rows) do
      {:ok, _count} ->
        # 적재 직후 도메인 sink 후처리(기본 NoopSink — 코어로 아무것도 안 흘림, 설계 §6.3).
        Ingest.configured_sink().handle_measurements(rows)
        messages

      {:error, reason} ->
        # batcher insert 전체 실패(CHECK 위반 등 영구 오류) → 배치 일괄 dead-letter(설계 §5.3).
        # 1차 검증을 통과한 row 들이므로 이 경로는 드물다(경보 대상).
        Logger.error("[ingest] 배치 적재 실패 → dead-letter 일괄 격리: #{inspect(reason)}")
        DeadLetter.capture_batch(rows, "batch_insert_failed")
        Enum.map(messages, &Message.failed(&1, reason))
    end
  end

  @impl true
  def handle_failed(messages, _ctx) do
    # handle_message 에서 이미 dead-letter 격리됨. 여기서는 사후 훅(필요 시 로깅)만.
    messages
  end
end
