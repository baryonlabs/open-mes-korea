defmodule OpenMes.Connect.DureClaw.SkillCache do
  @moduledoc """
  스킬 결정화 캐시 — "LLM as compiler" 의 *증류 산출물* 저장소.

  Claude(브레인)가 한 번 도출하고 **사람이 승인**한 결정을 *결정론적 룰*로 동결한다.
  같은 불량 패턴이 다시 오면 LLM 디스패치를 건너뛰고 µs 안에 룰로 응답한다.
  → "Claude 한 번 제대로, 그다음은 캐시" (토큰·지연 복리 절감).

  안전: **승인된 결정만 동결**한다(사람이 사인한 것만 캐시). 결정론적 실행이라 재현 가능.

  무상태 프로세스 없이 ETS 한 장으로 — 읽기 µs, 쓰기는 승인 시에만(희소).
  코어 도메인 미참조(확장 격리).
  """

  @table :dureclaw_skill_cache

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
  rule = `%{decision, llm_ms, approved_by, frozen_at}`.
  """
  def lookup(pattern_key) do
    ensure()
    t0 = System.monotonic_time(:microsecond)

    case :ets.lookup(@table, pattern_key) do
      [{^pattern_key, rule}] ->
        {:hit, rule, System.monotonic_time(:microsecond) - t0}

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
      frozen_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {pattern_key, rule})
    rule
  end

  @doc "동결된 룰 전체(대시보드 표시용)."
  def all do
    ensure()
    :ets.tab2list(@table) |> Enum.map(fn {k, r} -> Map.put(r, :pattern, k) end)
  end

  def forget(pattern_key) do
    ensure()
    :ets.delete(@table, pattern_key)
  end
end
