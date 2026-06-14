defmodule OpenMes.Production.Reports do
  @moduledoc """
  생산 조회/대시보드(G5) 읽기 전용 집계 모듈.

  쓰기 없음(AuditLog 무관). 모든 집계는 서버측 Ecto 쿼리 + 순수 함수로 산출한다.
  외부 차트 라이브러리 없이 표/텍스트 막대로 렌더되도록 단순 map/list 만 반환한다.

  주의(방어):
    - 빈 데이터에서도 안전하게 0/[]/nil 을 반환한다.
    - 비율 계산은 0 나눗셈을 방어한다(분모 0 이면 0.0).
  """
  import Ecto.Query, only: [from: 2]

  alias OpenMes.Production.{DefectRecord, Operation, ProductionResult, WorkOrder}
  alias OpenMes.Repo

  # ──────────────────────────────────────────────────────────────────
  # 1) 생산 현황 — 작업지시 상태별 집계
  # ──────────────────────────────────────────────────────────────────

  @work_order_statuses ~w(draft released in_progress completed cancelled)

  @doc """
  작업지시 상태별 건수 집계. 모든 정의 상태를 키로 포함하며(데이터 없으면 0),
  `:total` 키에 전체 건수를 담는다.
  """
  def work_order_status_counts do
    counts =
      from(w in WorkOrder, group_by: w.status, select: {w.status, count(w.id)})
      |> Repo.all()
      |> Map.new()

    base = Map.new(@work_order_statuses, fn s -> {s, Map.get(counts, s, 0)} end)
    Map.put(base, :total, Enum.sum(Map.values(counts)))
  end

  @doc "정의된 작업지시 상태 순서(대시보드 표시 순서)."
  def work_order_statuses, do: @work_order_statuses

  # ──────────────────────────────────────────────────────────────────
  # 2) 공정별 실적 — Process 별 양품/불량 집계
  # ──────────────────────────────────────────────────────────────────

  @doc """
  공정(Process)별 양품/불량 수량 집계.

  operations → production_results 를 process_id 로 묶어 good/defect 합계를 낸다.
  반환: [%{process_id, good_quantity: Decimal, defect_quantity: Decimal, total: Decimal,
          defect_rate: float, result_count: integer}] (양품+불량 많은 순).
  실적이 전혀 없으면 [].
  """
  def production_by_process do
    rows =
      from(o in Operation,
        join: r in ProductionResult,
        on: r.operation_id == o.id,
        group_by: o.process_id,
        select: %{
          process_id: o.process_id,
          good_quantity: coalesce(sum(r.good_quantity), 0),
          defect_quantity: coalesce(sum(r.defect_quantity), 0),
          result_count: count(r.id)
        }
      )
      |> Repo.all()

    rows
    |> Enum.map(&decorate_quantities/1)
    |> Enum.sort_by(& &1.total, &decimal_desc/2)
  end

  # ──────────────────────────────────────────────────────────────────
  # 3) 불량 현황 — 불량 유형별/기간별 집계
  # ──────────────────────────────────────────────────────────────────

  @doc """
  불량 유형(defect_code)별 수량 집계. 기간 필터(inserted_at 기준) 선택.

  period: %{from: DateTime | nil, to: DateTime | nil}. nil 이면 전체 기간.
  반환: [%{defect_code, quantity: Decimal, ratio: float}] (수량 많은 순). 비어 있으면 [].
  ratio 는 전체 불량 수량 대비 비율(0 나눗셈 방어).
  """
  def defects_by_code(period \\ %{}) do
    rows =
      DefectRecord
      |> defect_period(period)
      |> group_by_defect_code()
      |> Repo.all()
      |> Enum.map(fn {code, qty} -> %{defect_code: code, quantity: to_decimal(qty)} end)

    total = rows |> Enum.map(& &1.quantity) |> sum_decimals()

    rows
    |> Enum.map(fn row -> Map.put(row, :ratio, decimal_ratio(row.quantity, total)) end)
    |> Enum.sort_by(& &1.quantity, &decimal_desc/2)
  end

  @doc """
  기간 내 전체 양품/불량/생산 수량과 불량률 요약.
  반환: %{good_quantity, defect_quantity, total_quantity, defect_rate}. 데이터 없으면 0.
  """
  def defect_summary(period \\ %{}) do
    %{good: good, defect: defect} =
      ProductionResult
      |> result_period(period)
      |> from_select_good_defect()
      |> Repo.one()
      |> normalize_good_defect()

    total = Decimal.add(good, defect)

    %{
      good_quantity: good,
      defect_quantity: defect,
      total_quantity: total,
      defect_rate: decimal_ratio(defect, total)
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # 4) 대시보드 — 오늘 생산 요약 / 일별 시계열 (시각 대시보드용 신규)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  오늘(UTC 일자) 양품/불량/생산 수량 + 불량률 + 진행중 작업지시 건수 요약.

  ProductionResult.inserted_at >= 오늘 0시(UTC) 인 실적을 합산한다.
  반환: %{good_quantity, defect_quantity, total_quantity (Decimal),
          defect_rate (float 0..1), in_progress_work_orders (integer)}.
  실적/작업지시 없으면 0. 읽기 전용.
  """
  def today_production_summary do
    start_of_day = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    %{good: good, defect: defect} =
      ProductionResult
      |> from_where_gte(start_of_day)
      |> from_select_good_defect()
      |> Repo.one()
      |> normalize_good_defect()

    total = Decimal.add(good, defect)

    in_progress =
      from(w in WorkOrder, where: w.status == "in_progress", select: count(w.id))
      |> Repo.one()

    %{
      good_quantity: good,
      defect_quantity: defect,
      total_quantity: total,
      defect_rate: decimal_ratio(defect, total),
      in_progress_work_orders: in_progress || 0
    }
  end

  @doc """
  최근 N일(기본 7) 일자별 양품/불량 시계열(오름차순, 누락일은 0/0 으로 채움).

  ProductionResult.inserted_at 의 날짜(UTC)별로 good/defect 합을 낸다.
  반환: [%{date: ~D[...], good_quantity: Decimal, defect_quantity: Decimal}]
        (오래된→최신, 길이 = days). 빈 데이터여도 days 칸 모두 0 으로 반환(막대 차트 x축 고정).
  """
  def daily_production_series(days \\ 7) when is_integer(days) and days > 0 do
    today = Date.utc_today()
    from_date = Date.add(today, -(days - 1))
    start_dt = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")

    grouped =
      from(r in ProductionResult,
        where: r.inserted_at >= ^start_dt,
        group_by: fragment("date(?)", r.inserted_at),
        select: %{
          date: fragment("date(?)", r.inserted_at),
          good: coalesce(sum(r.good_quantity), 0),
          defect: coalesce(sum(r.defect_quantity), 0)
        }
      )
      |> Repo.all()
      |> Map.new(fn row ->
        {to_date(row.date), %{good: to_decimal(row.good), defect: to_decimal(row.defect)}}
      end)

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(from_date, offset)
      %{good: g, defect: d} = Map.get(grouped, date, %{good: Decimal.new(0), defect: Decimal.new(0)})
      %{date: date, good_quantity: g, defect_quantity: d}
    end)
  end

  @doc """
  작업지시 id 목록 → 각 작업지시의 누적 양품/불량 실적 맵.

  WorkOrder → Operation(work_order_id) → ProductionResult(operation_id) 체인을 따라
  good/defect 를 work_order 별로 합산한다(진행바 W4 의 계획 대비 실적 근사).
  반환: %{work_order_id => %{good_quantity: Decimal, defect_quantity: Decimal}}.
  빈 목록이거나 실적 없으면 빈 맵/0. 읽기 전용.
  """
  def produced_by_work_order(work_order_ids) when is_list(work_order_ids) do
    ids = Enum.uniq(work_order_ids)

    if ids == [] do
      %{}
    else
      from(o in Operation,
        join: r in ProductionResult,
        on: r.operation_id == o.id,
        where: o.work_order_id in ^ids,
        group_by: o.work_order_id,
        select: %{
          work_order_id: o.work_order_id,
          good: coalesce(sum(r.good_quantity), 0),
          defect: coalesce(sum(r.defect_quantity), 0)
        }
      )
      |> Repo.all()
      |> Map.new(fn row ->
        {row.work_order_id, %{good_quantity: to_decimal(row.good), defect_quantity: to_decimal(row.defect)}}
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼 (순수/쿼리)
  # ──────────────────────────────────────────────────────────────────

  # DB 가 반환하는 date 표현(%Date{} 또는 {y,m,d} 또는 binary)을 Date 로 정규화.
  defp to_date(%Date{} = d), do: d
  defp to_date({y, m, d}), do: Date.new!(y, m, d)
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  defp decorate_quantities(%{good_quantity: good, defect_quantity: defect} = row) do
    good = to_decimal(good)
    defect = to_decimal(defect)
    total = Decimal.add(good, defect)

    %{
      process_id: row.process_id,
      result_count: row.result_count,
      good_quantity: good,
      defect_quantity: defect,
      total: total,
      defect_rate: decimal_ratio(defect, total)
    }
  end

  defp defect_period(query, %{from: %DateTime{} = f} = period),
    do: query |> from_where_gte(f) |> defect_period(Map.delete(period, :from))

  defp defect_period(query, %{to: %DateTime{} = t} = period),
    do: query |> from_where_lte(t) |> defect_period(Map.delete(period, :to))

  defp defect_period(query, _), do: query

  defp result_period(query, %{from: %DateTime{} = f} = period),
    do: query |> from_where_gte(f) |> result_period(Map.delete(period, :from))

  defp result_period(query, %{to: %DateTime{} = t} = period),
    do: query |> from_where_lte(t) |> result_period(Map.delete(period, :to))

  defp result_period(query, _), do: query

  defp from_where_gte(query, dt), do: from(x in query, where: x.inserted_at >= ^dt)
  defp from_where_lte(query, dt), do: from(x in query, where: x.inserted_at <= ^dt)

  defp group_by_defect_code(query),
    do:
      from(d in query,
        group_by: d.defect_code,
        select: {d.defect_code, coalesce(sum(d.quantity), 0)}
      )

  defp from_select_good_defect(query),
    do:
      from(r in query,
        select: %{
          good: coalesce(sum(r.good_quantity), 0),
          defect: coalesce(sum(r.defect_quantity), 0)
        }
      )

  defp normalize_good_defect(nil), do: %{good: Decimal.new(0), defect: Decimal.new(0)}

  defp normalize_good_defect(%{good: g, defect: d}),
    do: %{good: to_decimal(g), defect: to_decimal(d)}

  # 0 나눗셈 방어 비율(Decimal → float, 0..1).
  defp decimal_ratio(part, %Decimal{} = total) do
    if Decimal.compare(total, Decimal.new(0)) == :eq do
      0.0
    else
      Decimal.div(to_decimal(part), total) |> Decimal.to_float()
    end
  end

  defp sum_decimals(list),
    do: Enum.reduce(list, Decimal.new(0), fn d, acc -> Decimal.add(acc, to_decimal(d)) end)

  # 내림차순 정렬용 비교자(큰 값이 앞으로).
  defp decimal_desc(a, b), do: Decimal.compare(to_decimal(a), to_decimal(b)) != :lt

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
  defp to_decimal(nil), do: Decimal.new(0)
end
