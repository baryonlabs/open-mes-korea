defmodule OpenMes.Addons.DefectStats.Stats do
  @moduledoc """
  애드온 ② 불량 통계 집계 — **읽기 전용**.

  설계 §2 애드온②: `DefectRecord`(defect_code, quantity)와
  `ProductionResult`(good_quantity, defect_quantity)를 읽어 다음을 집계한다.

    1. 불량 유형별 수량/비율 — `group_by defect_code`, `sum(quantity)`.
    2. 기간별 불량률 — `defect_quantity / (good_quantity + defect_quantity)`.

  ## 불변 규칙(설계 §0)

    - **Repo 읽기만**: `Repo.all/1`, `Repo.one/1` 등 SELECT 만 사용. 쓰기/AuditLog/Outbox 0.
    - **0 나눗셈 방어**: 분모(생산수량 = good + defect)가 0 이면 불량률을 `0.0` 으로 정의한다
      (EXT-1 멱등 교훈처럼 엣지케이스를 명시 처리 — 절대 raise/NaN 금지).
    - **순수 집계**: 계산 함수(`defect_rate/2`, `ratio/2`)는 부수효과 없는 순수 함수로 분리해
      테스트로 고정한다(DB 없이도 검증 가능).

  ## 기간 필터

  `ProductionResult.ended_at` 기준으로 `from`/`to`(둘 다 `DateTime` | `nil`)로 거른다.
  불량 유형별 집계는 `DefectRecord` 를 `ProductionResult` 에 조인하여 동일 기간 필터를 적용한다.
  """
  import Ecto.Query

  alias OpenMes.Addons.DefectStats.Schemas.{DefectRecord, ProductionResult}
  alias OpenMes.Repo

  @typedoc "기간 필터. 둘 다 nil 이면 전체 기간."
  @type period :: %{optional(:from) => DateTime.t() | nil, optional(:to) => DateTime.t() | nil}

  @typedoc "불량 유형별 집계 한 줄."
  @type defect_row :: %{
          defect_code: String.t(),
          quantity: integer(),
          ratio: float()
        }

  @typedoc "기간 요약."
  @type summary :: %{
          good_quantity: integer(),
          defect_quantity: integer(),
          total_quantity: integer(),
          defect_rate: float()
        }

  # ──────────────────────────────────────────────────────────────────
  # 공개 집계 API (읽기 전용)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  기간 요약: 총 양품/불량/생산수량과 불량률.

  불량률 = defect_quantity / (good_quantity + defect_quantity).
  생산수량(분모)이 0 이면 불량률은 `0.0`(0 나눗셈 방어).

  실적이 한 건도 없으면 모든 수량 0, 불량률 0.0 을 반환한다(nil 합계 방어).
  """
  @spec summary(period()) :: summary()
  def summary(period \\ %{}) do
    row =
      ProductionResult
      |> apply_period(period)
      |> select([pr], %{
        good: coalesce(sum(pr.good_quantity), 0),
        defect: coalesce(sum(pr.defect_quantity), 0)
      })
      |> Repo.one()

    good = to_int(row && row.good)
    defect = to_int(row && row.defect)
    total = good + defect

    %{
      good_quantity: good,
      defect_quantity: defect,
      total_quantity: total,
      defect_rate: defect_rate(defect, total)
    }
  end

  @doc """
  불량 유형별 집계(수량 내림차순). 각 행에 전체 불량 대비 비율을 포함한다.

  `defect_records` 를 `production_results` 에 조인하여 동일 기간 필터(`ended_at` 기준)를 적용한다.
  `limit` 으로 상위 N 만 반환(기본 전체). 전체 불량 합이 0 이면 모든 행의 ratio 는 0.0.
  """
  @spec defects_by_code(period(), keyword()) :: [defect_row()]
  def defects_by_code(period \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    rows =
      DefectRecord
      |> join(:inner, [d], pr in ProductionResult, on: d.production_result_id == pr.id)
      |> apply_period_on_join(period)
      |> group_by([d], d.defect_code)
      |> select([d], %{defect_code: d.defect_code, quantity: coalesce(sum(d.quantity), 0)})
      |> order_by([d], desc: coalesce(sum(d.quantity), 0))
      |> maybe_limit(limit)
      |> Repo.all()
      |> Enum.map(fn r -> %{defect_code: r.defect_code, quantity: to_int(r.quantity)} end)

    total = rows |> Enum.map(& &1.quantity) |> Enum.sum()

    Enum.map(rows, fn r -> Map.put(r, :ratio, ratio(r.quantity, total)) end)
  end

  # ──────────────────────────────────────────────────────────────────
  # 순수 계산 함수 (부수효과 없음 — 테스트로 고정)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  불량률 = defect / total. **0 나눗셈 방어**: total 이 0(또는 음수/비정상)이면 0.0.

  결과는 0.0..1.0 범위의 float. 백분율 표시는 호출 측에서 `* 100`.

      iex> defect_rate(0, 0)
      0.0
      iex> defect_rate(5, 100)
      0.05
  """
  @spec defect_rate(number(), number()) :: float()
  def defect_rate(_defect, total) when not is_number(total) or total <= 0, do: 0.0
  def defect_rate(defect, total) when is_number(defect), do: defect / total

  @doc """
  비율 = part / whole. **0 나눗셈 방어**: whole 이 0 이하면 0.0.

      iex> ratio(3, 12)
      0.25
      iex> ratio(1, 0)
      0.0
  """
  @spec ratio(number(), number()) :: float()
  def ratio(_part, whole) when not is_number(whole) or whole <= 0, do: 0.0
  def ratio(part, whole) when is_number(part), do: part / whole

  # ──────────────────────────────────────────────────────────────────
  # 기간 필터 (읽기 쿼리 빌더)
  # ──────────────────────────────────────────────────────────────────

  # ProductionResult 단독 쿼리에 ended_at 기간 필터 적용.
  defp apply_period(query, period) do
    query
    |> filter_from(period[:from])
    |> filter_to(period[:to])
  end

  defp filter_from(query, %DateTime{} = from),
    do: where(query, [pr], pr.ended_at >= ^from)

  defp filter_from(query, _), do: query

  defp filter_to(query, %DateTime{} = to),
    do: where(query, [pr], pr.ended_at <= ^to)

  defp filter_to(query, _), do: query

  # DefectRecord ⨝ ProductionResult 조인 쿼리에 pr.ended_at 기간 필터 적용(바인딩 인덱스 1 = pr).
  defp apply_period_on_join(query, period) do
    query
    |> filter_join_from(period[:from])
    |> filter_join_to(period[:to])
  end

  defp filter_join_from(query, %DateTime{} = from),
    do: where(query, [_d, pr], pr.ended_at >= ^from)

  defp filter_join_from(query, _), do: query

  defp filter_join_to(query, %DateTime{} = to),
    do: where(query, [_d, pr], pr.ended_at <= ^to)

  defp filter_join_to(query, _), do: query

  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
  defp maybe_limit(query, _), do: query

  # ──────────────────────────────────────────────────────────────────
  # 변환 헬퍼
  # ──────────────────────────────────────────────────────────────────

  # 수량은 :decimal 컬럼이다. sum 결과는 Decimal | nil 일 수 있다 → 정수로 정규화.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
end
