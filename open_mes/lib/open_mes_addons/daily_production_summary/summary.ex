defmodule OpenMes.Addons.DailyProductionSummary.Summary do
  @moduledoc """
  애드온 ⑤ 일일 생산 요약 — **읽기 전용** 집계 모듈.

  설계 §2 애드온⑤. 코어 데이터(`WorkOrder`/`ProductionResult`/`Operation`/`Item`)를
  Repo 읽기 쿼리로만 읽어 선택일의 요약을 만든다. 쓰기/AuditLog/Outbox/새 테이블 0.

  ## 집계 항목

    - `work_order_counts` : 작업지시 상태별 건수(전 상태) — `Production.list_work_orders/1` 재사용
    - `active_work_order_count` : 가동(in_progress) 작업지시 수
    - `total_good` / `total_defect` : 선택일에 종료된 실적(`ProductionResult.ended_at`) 합산
    - `by_item` : 품목별 양품/불량 합산(상위 N, 양품 내림차순)

  ## 날짜 경계(중요, 설계 필수 준수)

  "선택일"은 **타임존이 있는 날짜**다. UTC 로 저장된 `ended_at` 을 그 타임존의
  `[date 00:00:00, 다음날 00:00:00)` 반열린 구간으로 필터한다. 시작 포함/끝 배타로
  자정 경계가 양쪽 날짜에 중복 집계되지 않게 한다. 경계 계산은 순수 함수
  `day_bounds/2` 로 분리해 테스트로 고정한다.

  ## 안전성

    - 데이터가 없는 날도 `total_good=0`, `by_item=[]` 등 **빈 요약**으로 반환한다(raise 없음).
    - `summarize/2` 는 어떤 입력에도 raise 하지 않는다(타임존 미존재 시 UTC 로 폴백).
  """
  import Ecto.Query

  alias OpenMes.Addons.DailyProductionSummary.Schemas.Item
  alias OpenMes.Addons.DailyProductionSummary.Schemas.Operation
  alias OpenMes.Addons.DailyProductionSummary.Schemas.ProductionResult
  alias OpenMes.Repo

  @default_time_zone "Etc/UTC"
  @default_top_n 10

  # 도메인 모델 WorkOrder status 전체(요약 카드가 0건 상태도 표시하도록 기준 목록 사용).
  @work_order_statuses ~w(draft released in_progress completed cancelled)
  @active_status "in_progress"

  @typedoc "품목별 생산 집계 한 줄."
  @type item_row :: %{
          item_id: binary() | nil,
          item_code: String.t() | nil,
          item_name: String.t() | nil,
          good: Decimal.t(),
          defect: Decimal.t()
        }

  @typedoc "일일 생산 요약 결과."
  @type t :: %{
          date: Date.t(),
          time_zone: String.t(),
          work_order_counts: %{String.t() => non_neg_integer()},
          total_work_orders: non_neg_integer(),
          active_work_order_count: non_neg_integer(),
          total_good: Decimal.t(),
          total_defect: Decimal.t(),
          defect_rate: float(),
          by_item: [item_row()],
          result_count: non_neg_integer()
        }

  @doc """
  선택일(`date`)의 생산 요약을 만든다. 옵션은 `OpenMes.Addons.DailyProductionSummary.summarize/2` 참조.

  데이터가 없으면 빈 요약(0/[])을 반환한다. raise 하지 않는다.
  """
  @spec summarize(Date.t(), keyword()) :: t()
  def summarize(%Date{} = date, opts \\ []) do
    time_zone = Keyword.get(opts, :time_zone, @default_time_zone)
    top_n = opts |> Keyword.get(:top_n, @default_top_n) |> normalize_top_n()

    {from_dt, to_dt, effective_tz} = day_bounds(date, time_zone)

    wo_counts = work_order_counts()
    {total_good, total_defect, result_count} = production_totals(from_dt, to_dt)
    by_item = production_by_item(from_dt, to_dt, top_n)

    %{
      date: date,
      time_zone: effective_tz,
      work_order_counts: wo_counts,
      total_work_orders: wo_counts |> Map.values() |> Enum.sum(),
      active_work_order_count: Map.get(wo_counts, @active_status, 0),
      total_good: total_good,
      total_defect: total_defect,
      defect_rate: defect_rate(total_good, total_defect),
      by_item: by_item,
      result_count: result_count
    }
  end

  # ── 날짜 경계(순수 함수) ────────────────────────────────────────────

  @doc """
  선택일 `date` 의 `[시작, 끝)` UTC 경계를 계산한다(순수 함수).

  주어진 타임존에서 그 날의 00:00:00 ~ 다음날 00:00:00 을 만들어 UTC 로 변환한다.
  반환: `{from_utc :: DateTime.t(), to_utc :: DateTime.t(), effective_time_zone :: String.t()}`.
  `to_utc` 는 **배타(미포함)** 경계다(`ended_at < to_utc`).

  타임존 DB 가 없거나 알 수 없는 타임존이면 UTC 로 안전 폴백한다(raise 없음).
  """
  @spec day_bounds(Date.t(), String.t()) :: {DateTime.t(), DateTime.t(), String.t()}
  def day_bounds(%Date{} = date, time_zone) do
    next_date = Date.add(date, 1)

    with {:ok, from_local} <- naive_to_zoned(date, time_zone),
         {:ok, to_local} <- naive_to_zoned(next_date, time_zone) do
      {DateTime.shift_zone!(from_local, "Etc/UTC"), DateTime.shift_zone!(to_local, "Etc/UTC"),
       time_zone}
    else
      # 타임존 DB 부재/미존재 타임존 → UTC 경계로 폴백(안전 처리).
      _ ->
        from_utc = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
        to_utc = DateTime.new!(next_date, ~T[00:00:00.000000], "Etc/UTC")
        {from_utc, to_utc, "Etc/UTC"}
    end
  end

  # 자정(00:00:00)을 주어진 타임존의 DateTime 으로. 타임존 DB 가 없으면 :error.
  defp naive_to_zoned(%Date{} = date, time_zone) do
    DateTime.new(date, ~T[00:00:00.000000], time_zone)
  rescue
    # tz database 미설정(ArgumentError) 등은 폴백 경로로 보냄.
    _ -> :error
  end

  # ── 작업지시 집계(코어 공개 함수 재사용) ─────────────────────────────

  # 상태별 작업지시 건수. 코어 공개 조회 함수를 상태별로 호출(읽기 전용, 코어 비침투).
  # 상태 목록은 도메인 모델 기준 전체를 사용해 0건 상태도 카드에 표시한다.
  defp work_order_counts do
    Map.new(@work_order_statuses, fn status ->
      count =
        %{"status" => status, "limit" => "200"}
        |> OpenMes.Production.list_work_orders()
        |> length()

      {status, count}
    end)
  end

  # ── 실적 집계(읽기 전용 Ecto 쿼리) ──────────────────────────────────

  # 선택일에 종료된 실적의 총 양품/불량/건수. ended_at 이 [from, to) 인 것만.
  defp production_totals(from_dt, to_dt) do
    query =
      from r in ProductionResult,
        where: not is_nil(r.ended_at) and r.ended_at >= ^from_dt and r.ended_at < ^to_dt,
        select: %{
          good: coalesce(sum(r.good_quantity), 0),
          defect: coalesce(sum(r.defect_quantity), 0),
          count: count(r.id)
        }

    case Repo.one(query) do
      nil -> {Decimal.new(0), Decimal.new(0), 0}
      %{good: good, defect: defect, count: count} -> {to_decimal(good), to_decimal(defect), count}
    end
  end

  # 품목별 양품/불량 합산(상위 N, 양품 내림차순).
  # 조인 체인: ProductionResult → Operation(operation_id) → WorkOrder(work_order_id)
  #            → Item(item_id). work_orders 는 코어 테이블이지만 읽기 전용 조인만 한다.
  defp production_by_item(from_dt, to_dt, top_n) do
    query =
      from r in ProductionResult,
        where: not is_nil(r.ended_at) and r.ended_at >= ^from_dt and r.ended_at < ^to_dt,
        join: op in Operation,
        on: op.id == r.operation_id,
        join: wo in "work_orders",
        on: wo.id == op.work_order_id,
        left_join: it in Item,
        on: it.id == wo.item_id,
        group_by: [wo.item_id, it.item_code, it.name],
        select: %{
          item_id: wo.item_id,
          item_code: it.item_code,
          item_name: it.name,
          good: coalesce(sum(r.good_quantity), 0),
          defect: coalesce(sum(r.defect_quantity), 0)
        }

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        item_id: row.item_id,
        item_code: row.item_code,
        item_name: row.item_name,
        good: to_decimal(row.good),
        defect: to_decimal(row.defect)
      }
    end)
    |> Enum.sort_by(& &1.good, &decimal_desc/2)
    |> Enum.take(top_n)
  end

  # ── 순수 헬퍼 ───────────────────────────────────────────────────────

  # 불량률 = defect / (good + defect). 분모 0 이면 0.0.
  @doc false
  @spec defect_rate(Decimal.t(), Decimal.t()) :: float()
  def defect_rate(%Decimal{} = good, %Decimal{} = defect) do
    total = Decimal.add(good, defect)

    if Decimal.equal?(total, 0) do
      0.0
    else
      defect
      |> Decimal.div(total)
      |> Decimal.round(4)
      |> Decimal.to_float()
    end
  end

  defp decimal_desc(a, b), do: Decimal.compare(a, b) != :lt

  defp normalize_top_n(n) when is_integer(n) and n > 0, do: n
  defp normalize_top_n(_), do: @default_top_n

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: Decimal.new(0)
end
