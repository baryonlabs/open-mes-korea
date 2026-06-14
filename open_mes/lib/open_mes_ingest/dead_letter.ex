defmodule OpenMes.Ingest.DeadLetter do
  @moduledoc """
  검증 실패(오염) 메시지를 ingest_dead_letters 에 격리한다. 설계 §5.

  오염 데이터(garbage in)는 재시도해도 영원히 실패하므로 즉시 격리하고
  파이프라인에서는 Message.failed 로 재시도 루프를 차단한다(Pipeline 참조).

  코어 의존: `OpenMes.Repo` 만. append-only(정정/삭제 함수 없음).
  이것은 AuditLog 가 아니다 — 수집 오류 격리소이며 코어 audit_logs 와 무관(설계 §5.2).
  """
  alias OpenMes.Repo
  alias OpenMes.Ingest.DeadLetterRecord

  require Logger

  @doc """
  단건 오염 메시지를 격리한다.

  - `raw` : 원본 메시지(map 이 아니어도 보존 위해 래핑)
  - `reason` : 실패 사유 문자열(Validator 가 만든 사유)
  - `source` : 디바이스 토큰 라벨(옵션)
  """
  @spec capture(term(), String.t(), String.t() | nil) :: :ok
  def capture(raw, reason, source \\ nil) do
    attrs = %{
      raw_payload: wrap(raw),
      reason: to_string(reason),
      source: source
    }

    case attrs |> DeadLetterRecord.changeset() |> Repo.insert() do
      {:ok, _record} ->
        :ok

      {:error, changeset} ->
        # 격리 자체가 실패하면(예: DB 장애) 최소한 로그로 남긴다. 데이터 유실 가시화.
        Logger.error("[ingest] dead-letter 격리 실패: #{inspect(changeset.errors)} raw=#{inspect(raw)}")
        :ok
    end
  end

  @doc """
  batcher insert 전체 실패 시, 해당 배치 row 들을 일괄 격리한다(설계 §5.3).
  행 단위 재분할 재시도는 후속(과설계 회피).
  """
  @spec capture_batch([map()], String.t(), String.t() | nil) :: :ok
  def capture_batch(rows, reason, source \\ nil) when is_list(rows) do
    Enum.each(rows, &capture(&1, reason, source))
    :ok
  end

  # 격리 컬럼(raw_payload)은 jsonb(map)이다. map 이 아닌 원본은 래핑해 보존한다.
  defp wrap(raw) when is_map(raw), do: raw
  defp wrap(raw), do: %{"_raw" => inspect(raw)}
end
