defmodule OpenMes.Connect.DureClaw.SkillCache do
  @moduledoc """
  스킬 결정화 캐시 — "LLM as compiler" 의 *증류 산출물* 저장소.

  Claude(브레인)가 한 번 도출하고 **사람이 승인**한 결정을 *결정론적 룰*로 동결한다.
  같은 불량 패턴이 다시 오면 LLM 디스패치를 건너뛰고 µs 안에 룰로 응답한다.
  → "Claude 한 번 제대로, 그다음은 캐시" (토큰·지연 복리 절감).

  안전: **승인된 결정만 동결**한다(사람이 사인한 것만 캐시). 결정론적 실행이라 재현 가능.

  ## 저장 구조

  ETS 한 장(`:dureclaw_skill_cache`, named/public/set). 읽기·쓰기 모두 직접 ETS(µs 핫패스).
  테이블 소유는 `SkillCache.Server`(아래) — 감독 트리에 매달려 페이지 reload·요청 프로세스
  종료와 무관하게 **동결 룰이 살아남는다**(대시보드 상시 표시 요건). 서버 init 은 테이블 생성만
  하고 idle — crash 유발 콜백 0(무대 안정성, MES.Bus 교훈 적용). 서버 미기동(테스트 등) 시
  `ensure/0` 가 lazy 생성하는 fallback 도 유지.

  코어 도메인 미참조(확장 격리).

  ## 룰 스키마

      %{decision, llm_ms, approved_by, frozen_at, hits, last_hit_us}

  - `hits` — 동결 후 결정론적 재사용(캐시 히트) 횟수. 절감 LLM 호출 수.
  - `last_hit_us` — 마지막 캐시 히트 조회 소요(µs).
  """

  @table :dureclaw_skill_cache

  @doc false
  def table, do: @table

  defp ensure do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  @doc """
  패턴 룰 조회. 히트면 `{:hit, rule, hit_us}` (조회 소요 µs 포함), 미스면 `:miss`.
  히트 시 `hits` 를 +1, `last_hit_us` 갱신(절감 집계용). 측정된 `hit_us` 는 순수 조회 시간만
  포함(증가 write 는 측정 후) — 광고하는 "캐시 히트 µs" 의 정직성 유지.
  rule = `%{decision, llm_ms, approved_by, frozen_at, hits, last_hit_us}`.
  """
  def lookup(pattern_key) do
    ensure()
    t0 = System.monotonic_time(:microsecond)

    case :ets.lookup(@table, pattern_key) do
      [{^pattern_key, rule}] ->
        hit_us = System.monotonic_time(:microsecond) - t0

        # 데모 cadence(클릭)에서 read-modify-write 경합 무시 가능. 히트 카운트는 측정 후 기록.
        updated = %{rule | hits: (rule[:hits] || 0) + 1, last_hit_us: hit_us}
        :ets.insert(@table, {pattern_key, updated})
        {:hit, updated, hit_us}

      [] ->
        :miss
    end
  end

  @doc "승인된 결정을 룰로 동결(결정화). llm_ms = 1회차 LLM 라운드트립 소요(ms)."
  def crystallize(pattern_key, decision, opts \\ []) do
    ensure()

    rule = %{
      decision: decision,
      llm_ms: Keyword.get(opts, :llm_ms),
      approved_by: Keyword.get(opts, :approved_by, "manager"),
      frozen_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      hits: 0,
      last_hit_us: nil
    }

    :ets.insert(@table, {pattern_key, rule})
    rule
  end

  @doc "동결된 룰 전체(대시보드 표시용). 조회는 hits 를 증가시키지 않는다(lookup 만 증가)."
  def all do
    ensure()
    :ets.tab2list(@table) |> Enum.map(fn {k, r} -> Map.put(r, :pattern, k) end)
  end

  @doc """
  결정화 누적 통계(대시보드용). RSI 학습 루프의 "이야기" 를 수치로.

      %{rule_count, total_hits, saved_ms, avg_hit_us, rules}

  - `total_hits` — 절감된 LLM 호출 수(동결 후 재사용 횟수 합).
  - `saved_ms` — Σ(룰별 hits × llm_ms). 재사용 1회당 LLM 라운드트립 1회를 아낀 것으로 추정.
  - `avg_hit_us` — 캐시 히트 평균 조회 µs(last_hit_us 평균, 없으면 nil).
  """
  def stats do
    rules = all()
    hit = fn r -> r[:hits] || 0 end

    total_hits = rules |> Enum.map(hit) |> Enum.sum()
    saved_ms = rules |> Enum.map(fn r -> hit.(r) * (r[:llm_ms] || 0) end) |> Enum.sum()
    hit_uss = rules |> Enum.map(& &1[:last_hit_us]) |> Enum.reject(&is_nil/1)

    avg_hit_us =
      case hit_uss do
        [] -> nil
        list -> round(Enum.sum(list) / length(list))
      end

    %{
      rule_count: length(rules),
      total_hits: total_hits,
      saved_ms: saved_ms,
      avg_hit_us: avg_hit_us,
      rules: Enum.sort_by(rules, & &1[:frozen_at], :desc)
    }
  end

  def forget(pattern_key) do
    ensure()
    :ets.delete(@table, pattern_key)
  end
end

defmodule OpenMes.Connect.DureClaw.SkillCache.Server do
  @moduledoc """
  SkillCache ETS 테이블 소유자(감독 트리 child). init 에서 테이블을 생성·소유만 하고 idle.

  목적: 동결 룰(SkillCache)과 통신 로그(EventLog)가 *전송 프로세스 수명*(LiveView·Task)과
  무관하게 살아남게 한다 — 대시보드·디버그 모니터 상시 표시 + reload 후에도 유지. 핫패스는
  여전히 직접 ETS(GenServer 호출 0). crash 유발 콜백 없음(MES.Bus 교훈: 소유 전용, 로직 0).

  config 게이트로 DureClaw 확장 enabled 시에만 application.ex 가 기동(코어 비침투).
  """
  use GenServer

  alias OpenMes.Connect.DureClaw.SkillCache
  alias OpenMes.Connect.DureClaw.EventLog

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    own(SkillCache.table(), :set)
    own(EventLog.table(), :ordered_set)
    {:ok, %{tables: [SkillCache.table(), EventLog.table()]}}
  end

  defp own(table, type) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, type, read_concurrency: true])
      _ -> :ok
    end
  end
end
