defmodule OpenMes.Ingest.Loader do
  @moduledoc """
  검증된 measurement row 배치를 TimescaleDB hypertable 에 벌크 적재한다. 설계 §3.2, §5.3.

  코어 의존: `OpenMes.Repo` 만(같은 DB 인프라). 코어 도메인 모듈은 참조하지 않는다.

  AuditLog 경계(설계 §0-B, §7.3): 텔레메트리는 고빈도 append-only 이므로
  건건 AuditLog 를 달지 않는다. append-only hypertable 자체가 이력성을 보장한다.
  이것은 누락이 아니라 의도된 설계 결정이다.
  """
  alias OpenMes.Repo
  alias OpenMes.Ingest.Measurement

  require Logger

  @doc """
  row map 리스트를 `Repo.insert_all/3` 로 한 번에 적재한다.

  반환:
    - `{:ok, count}` — 적재 성공(count 행)
    - `{:error, reason}` — batcher 전체 실패(부분 실패 격리는 호출부에서 처리, 설계 §5.3)

  주의: insert_all 은 단일 트랜잭션이므로 CHECK 위반 1건이 배치 전체를 롤백시킨다.
  1차 검증(Validator)에서 CHECK 위반 가능 데이터를 걸러 batcher 오염을 최소화한다.
  """
  @spec bulk_insert([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def bulk_insert([]), do: {:ok, 0}

  def bulk_insert(rows) when is_list(rows) do
    {count, _} = Repo.insert_all(Measurement, rows)
    {:ok, count}
  rescue
    error ->
      # DB 일시 오류(커넥션 등)는 Broadway 가 배치 재처리하도록 예외를 다시 던진다.
      # 영구 오류(CHECK 위반 등)는 batcher 콜백(Pipeline.handle_batch)에서 dead-letter 격리.
      Logger.error("[ingest] 벌크 적재 실패: #{inspect(error)}")
      {:error, error}
  end
end
