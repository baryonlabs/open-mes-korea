defmodule OpenMes.Ingest do
  @moduledoc """
  설비 데이터 수집 확장의 **공개 퍼사드**. 설계 §1.2, §6.1.

  컨트롤러의 유일한 진입점이다. 코어는 이 모듈/네임스페이스에 일절 의존하지 않으며,
  의존 방향은 확장 → 코어 단방향만 허용한다.

  주요 책임:
    - `enabled?/0` : config 플래그로 확장 활성 여부 판정(application.ex/router.ex 게이트).
    - `push/1`, `push/2` : 수집 메시지를 Broadway producer 큐에 적재(즉시 반환, 202용).
    - `configured_sink/0` : DomainSink 구현체 조회(기본 NoopSink).
    - `queue_depth/0` : 헬스 체크용 큐 깊이.
  """
  alias OpenMes.Ingest.BufferProducer
  alias OpenMes.Ingest.Sink.NoopSink

  @doc """
  확장 활성 여부. config `:enabled` 플래그 기준.
  false 면 application.ex 가 Broadway child 를 띄우지 않고, router 도 /ingest scope 를
  등록하지 않는다(코어 영향 0).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config() |> Keyword.get(:enabled, false) == true
  end

  @doc """
  단건 수집 메시지를 producer 큐에 적재한다.

  - `:ok` — 큐 적재 성공(검증/적재 결과는 기다리지 않는다 — 비동기 202).
  - `{:error, :busy}` — 큐 상한 초과(→ 컨트롤러 429 백프레셔).

  컨트롤러는 절대 검증/DB 결과를 기다리지 않는다(고처리량 핵심, 설계 §4).
  """
  @spec push(term()) :: :ok | {:error, :busy}
  def push(payload), do: BufferProducer.push(payload)

  @doc """
  배치(리스트) 적재. 각 원소를 개별 메시지로 push 한다(설계 §4.1 배열 수신).

  반환: `{accepted, rejected}` — 적재 성공/거부(busy) 건수.
  하나라도 busy 면 그 시점부터의 잔여는 거부로 집계된다(백프레셔 전파).
  """
  @spec push_many([term()]) :: {non_neg_integer(), non_neg_integer()}
  def push_many(payloads) when is_list(payloads) do
    Enum.reduce(payloads, {0, 0}, fn payload, {ok, busy} ->
      case push(payload) do
        :ok -> {ok + 1, busy}
        {:error, :busy} -> {ok, busy + 1}
      end
    end)
  end

  @doc "설정된 DomainSink 구현체. 기본값 NoopSink(텔레메트리 적재만, 코어 무연계)."
  @spec configured_sink() :: module()
  def configured_sink do
    config() |> Keyword.get(:sink, NoopSink)
  end

  @doc "현재 producer 큐 깊이(헬스 체크용). 확장 비활성 시 0."
  @spec queue_depth() :: non_neg_integer()
  def queue_depth do
    if enabled?() do
      try do
        BufferProducer.queue_len()
      catch
        # 파이프라인이 아직 안 떴거나 종료 중인 경우
        :exit, _ -> 0
      end
    else
      0
    end
  end

  defp config do
    Application.get_env(:open_mes, __MODULE__, [])
  end
end
