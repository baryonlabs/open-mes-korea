defmodule OpenMes.Addons.DailyProductionSummary.SummaryTest do
  @moduledoc """
  애드온 ⑤ 집계 정확성 테스트.

  검증 포인트(설계 §7-b):
    - 날짜 경계: `ended_at` 이 선택일 [00:00, 24:00) 인 실적만 집계(자정 경계 양끝 정확).
    - 품목별 합산: 같은 품목의 여러 실적이 합산되고, 양품 내림차순 정렬.
    - 데이터 없는 날: 빈 요약(0/[]) 으로 안전 반환(raise 없음).
    - 가동 작업지시 수: in_progress 상태 카운트.
    - 순수 함수 day_bounds/2 의 경계 계산.

  데이터 시딩은 읽기 전용 스키마가 changeset 을 제공하지 않으므로 `Repo.insert_all`
  (또는 코어 공개 함수)로 직접 행을 넣는다 — 애드온 자신은 읽기만 한다.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Addons.DailyProductionSummary.Summary

  @tz "Etc/UTC"

  # ── 시딩 헬퍼(테스트 전용 — 애드온 코드는 쓰기 없음) ──────────────────

  defp uuid, do: Ecto.UUID.generate()

  defp insert_item(attrs) do
    id = uuid()

    {1, _} =
      Repo.insert_all("items", [
        Map.merge(
          %{
            id: Ecto.UUID.dump!(id),
            item_code: "ITM",
            name: "품목",
            item_type: "product",
            unit: "EA",
            active: true,
            inserted_at: now(),
            updated_at: now()
          },
          attrs
        )
      ])

    id
  end

  defp insert_work_order(item_id, status) do
    id = uuid()

    {1, _} =
      Repo.insert_all("work_orders", [
        %{
          id: Ecto.UUID.dump!(id),
          work_order_no: "WO-" <> String.slice(uuid(), 0, 8),
          item_id: Ecto.UUID.dump!(item_id),
          planned_quantity: Decimal.new(100),
          status: status,
          inserted_at: now(),
          updated_at: now()
        }
      ])

    id
  end

  defp insert_operation(work_order_id) do
    id = uuid()

    {1, _} =
      Repo.insert_all("operations", [
        %{
          id: Ecto.UUID.dump!(id),
          work_order_id: Ecto.UUID.dump!(work_order_id),
          sequence: 1,
          status: "completed",
          inserted_at: now(),
          updated_at: now()
        }
      ])

    id
  end

  defp insert_result(operation_id, good, defect, ended_at) do
    {1, _} =
      Repo.insert_all("production_results", [
        %{
          id: Ecto.UUID.dump!(uuid()),
          operation_id: Ecto.UUID.dump!(operation_id),
          good_quantity: Decimal.new(good),
          defect_quantity: Decimal.new(defect),
          ended_at: ended_at,
          inserted_at: now(),
          updated_at: now()
        }
      ])

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # 품목 + 작업지시 + 공정 + 실적 한 세트를 만들고 실적의 ended_at 을 지정.
  defp seed_result(item_id, good, defect, ended_at, wo_status \\ "completed") do
    wo = insert_work_order(item_id, wo_status)
    op = insert_operation(wo)
    insert_result(op, good, defect, ended_at)
  end

  # ── 날짜 경계 ───────────────────────────────────────────────────────

  describe "날짜 경계" do
    test "선택일 00:00:00 실적은 포함, 다음날 00:00:00 실적은 제외" do
      item = insert_item(%{item_code: "A"})
      date = ~D[2026-06-13]

      # 경계: 당일 시작(포함)
      seed_result(item, 10, 1, ~U[2026-06-13 00:00:00.000000Z])
      # 경계: 당일 마지막 순간(포함)
      seed_result(item, 20, 2, ~U[2026-06-13 23:59:59.999999Z])
      # 경계: 다음날 시작(배타 — 제외돼야 함)
      seed_result(item, 999, 99, ~U[2026-06-14 00:00:00.000000Z])
      # 전날(제외)
      seed_result(item, 888, 88, ~U[2026-06-12 23:59:59.999999Z])

      summary = Summary.summarize(date, time_zone: @tz)

      assert Decimal.equal?(summary.total_good, Decimal.new(30))
      assert Decimal.equal?(summary.total_defect, Decimal.new(3))
      assert summary.result_count == 2
    end

    test "ended_at 이 nil 인 실적(미종료)은 집계되지 않는다" do
      item = insert_item(%{item_code: "A"})
      seed_result(item, 50, 5, nil)

      summary = Summary.summarize(~D[2026-06-13], time_zone: @tz)
      assert Decimal.equal?(summary.total_good, Decimal.new(0))
      assert summary.result_count == 0
    end

    test "day_bounds/2 는 [시작, 다음날 시작) UTC 경계를 반환(순수 함수)" do
      {from, to, tz} = Summary.day_bounds(~D[2026-06-13], "Etc/UTC")

      assert DateTime.to_iso8601(from) == "2026-06-13T00:00:00.000000Z"
      assert DateTime.to_iso8601(to) == "2026-06-14T00:00:00.000000Z"
      assert tz == "Etc/UTC"
    end

    test "day_bounds/2 는 알 수 없는 타임존이면 UTC 로 안전 폴백" do
      {_from, _to, tz} = Summary.day_bounds(~D[2026-06-13], "Mars/Olympus")
      assert tz == "Etc/UTC"
    end
  end

  # ── 품목별 합산 ─────────────────────────────────────────────────────

  describe "품목별 합산" do
    test "같은 품목의 여러 실적이 합산되고 양품 내림차순 정렬된다" do
      item_a = insert_item(%{item_code: "A", name: "품목A"})
      item_b = insert_item(%{item_code: "B", name: "품목B"})
      ended = ~U[2026-06-13 10:00:00.000000Z]

      # 품목A: 실적 2건 합산 → good 30, defect 3
      seed_result(item_a, 10, 1, ended)
      seed_result(item_a, 20, 2, ended)
      # 품목B: good 50, defect 5 (양품이 더 많아 위로 정렬돼야 함)
      seed_result(item_b, 50, 5, ended)

      summary = Summary.summarize(~D[2026-06-13], time_zone: @tz)

      assert [first, second] = summary.by_item
      assert first.item_code == "B"
      assert Decimal.equal?(first.good, Decimal.new(50))
      assert second.item_code == "A"
      assert Decimal.equal?(second.good, Decimal.new(30))
      assert Decimal.equal?(second.defect, Decimal.new(3))

      # 전체 합도 일치
      assert Decimal.equal?(summary.total_good, Decimal.new(80))
      assert Decimal.equal?(summary.total_defect, Decimal.new(8))
    end

    test "top_n 옵션으로 품목 표시 개수를 제한" do
      ended = ~U[2026-06-13 10:00:00.000000Z]

      for i <- 1..5 do
        item = insert_item(%{item_code: "C#{i}"})
        seed_result(item, i * 10, 0, ended)
      end

      summary = Summary.summarize(~D[2026-06-13], time_zone: @tz, top_n: 3)
      assert length(summary.by_item) == 3
      # 양품 내림차순 → 50, 40, 30
      assert Enum.map(summary.by_item, &Decimal.to_integer(&1.good)) == [50, 40, 30]
    end
  end

  # ── 작업지시 카운트 ─────────────────────────────────────────────────

  describe "작업지시 카운트" do
    test "가동(in_progress) 작업지시 수와 상태별 건수" do
      item = insert_item(%{item_code: "A"})
      insert_work_order(item, "in_progress")
      insert_work_order(item, "in_progress")
      insert_work_order(item, "completed")
      insert_work_order(item, "draft")

      summary = Summary.summarize(~D[2026-06-13], time_zone: @tz)

      assert summary.active_work_order_count == 2
      assert Map.get(summary.work_order_counts, "completed") == 1
      assert Map.get(summary.work_order_counts, "draft") == 1
      assert summary.total_work_orders == 4
    end
  end

  # ── 데이터 없는 날 방어 ──────────────────────────────────────────────

  describe "데이터 없는 날" do
    test "실적/작업지시가 전혀 없으면 빈 요약(0/[])으로 안전 반환" do
      summary = Summary.summarize(~D[2030-01-01], time_zone: @tz)

      assert Decimal.equal?(summary.total_good, Decimal.new(0))
      assert Decimal.equal?(summary.total_defect, Decimal.new(0))
      assert summary.defect_rate == 0.0
      assert summary.by_item == []
      assert summary.active_work_order_count == 0
      assert summary.result_count == 0
      # 상태별 카운트는 0 으로라도 모든 키가 존재
      assert Map.get(summary.work_order_counts, "in_progress") == 0
    end
  end

  # ── 불량률 ──────────────────────────────────────────────────────────

  describe "defect_rate/2 (순수 함수)" do
    test "불량률 = defect / (good + defect)" do
      assert Summary.defect_rate(Decimal.new(90), Decimal.new(10)) == 0.1
    end

    test "분모가 0 이면 0.0" do
      assert Summary.defect_rate(Decimal.new(0), Decimal.new(0)) == 0.0
    end
  end
end
