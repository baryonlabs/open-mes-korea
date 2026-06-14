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
  import Ecto.Query, only: [from: 2]

  alias OpenMes.Ingest.BufferProducer
  alias OpenMes.Ingest.Sink.NoopSink
  alias OpenMes.Repo

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

  # ──────────────────────────────────────────────────────────────────
  # AI 조사용 읽기(EXT-1) — 집계 + 다운샘플. raw 전량 조회 함수는 두지 않는다.
  # measured_at 으로 기간 필터. equipment_id 는 디바이스 키(=equipment_code 문자열).
  # AuditLog 불필요(텔레메트리 hypertable 읽기 — CLAUDE.md L35).
  # ──────────────────────────────────────────────────────────────────

  @doc """
  설비/기간별 metric_key 통계 요약(DB 집계 — raw 전량 금지).

  반환: `[%{metric_key, unit, count, avg, min, max, last}]` (metric_key 오름차순).
  `last` 는 측정시각 기준 최근값(DISTINCT ON). 데이터 없으면 [].
  """
  @spec summarize_metrics(String.t(), DateTime.t(), DateTime.t()) :: [map()]
  def summarize_metrics(equipment_id, from_dt, to_dt) when is_binary(equipment_id) do
    aggregates =
      from(m in "equipment_measurements",
        where:
          m.equipment_id == ^equipment_id and m.measured_at >= ^from_dt and
            m.measured_at <= ^to_dt and not is_nil(m.value),
        group_by: m.metric_key,
        order_by: m.metric_key,
        select: %{
          metric_key: m.metric_key,
          unit: fragment("max(?)", m.unit),
          count: count(m.value),
          avg: avg(m.value),
          min: min(m.value),
          max: max(m.value)
        }
      )
      |> Repo.all()

    last_by_metric = last_values(equipment_id, from_dt, to_dt)

    Enum.map(aggregates, fn agg ->
      %{
        metric_key: agg.metric_key,
        unit: agg.unit,
        count: agg.count,
        avg: to_f(agg.avg),
        min: to_f(agg.min),
        max: to_f(agg.max),
        last: Map.get(last_by_metric, agg.metric_key)
      }
    end)
  end

  # metric_key 별 최근값(measured_at 최대). TimescaleDB last() 대신 이식성 위해 DISTINCT ON 사용.
  defp last_values(equipment_id, from_dt, to_dt) do
    from(m in "equipment_measurements",
      where:
        m.equipment_id == ^equipment_id and m.measured_at >= ^from_dt and
          m.measured_at <= ^to_dt and not is_nil(m.value),
      distinct: m.metric_key,
      order_by: [asc: m.metric_key, desc: m.measured_at],
      select: {m.metric_key, m.value}
    )
    |> Repo.all()
    |> Map.new(fn {k, v} -> {k, to_f(v)} end)
  end

  @doc """
  설비/metric/기간 다운샘플 시리즈(시간 버킷 평균 ≤ buckets 포인트, 시각 오름차순).

  TimescaleDB `time_bucket` 으로 균등 버킷 평균을 낸다. 버킷 폭은 기간/buckets 로 산정해
  포인트 수가 buckets 를 넘지 않도록 한다(토큰 안전). 반환: `[%{t: DateTime, v: float}]`.
  """
  @spec downsample(String.t(), String.t(), DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def downsample(equipment_id, metric_key, from_dt, to_dt, buckets \\ 60)
      when is_binary(equipment_id) and is_binary(metric_key) and buckets > 0 do
    span_s = max(DateTime.diff(to_dt, from_dt, :second), 1)
    bucket_s = max(div(span_s, buckets), 1)

    from(m in "equipment_measurements",
      where:
        m.equipment_id == ^equipment_id and m.metric_key == ^metric_key and
          m.measured_at >= ^from_dt and m.measured_at <= ^to_dt and not is_nil(m.value),
      group_by: selected_as(:bucket),
      order_by: selected_as(:bucket),
      select: %{
        t:
          selected_as(
            fragment("time_bucket(make_interval(secs => ?), ?)", ^bucket_s, m.measured_at),
            :bucket
          ),
        v: avg(m.value)
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{t: t, v: v} -> %{t: to_utc(t), v: to_f(v)} end)
  end

  defp to_f(nil), do: nil
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_integer(n), do: n * 1.0
  defp to_f(n) when is_float(n), do: n

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp to_utc(other), do: other

  defp config do
    Application.get_env(:open_mes, __MODULE__, [])
  end
end
