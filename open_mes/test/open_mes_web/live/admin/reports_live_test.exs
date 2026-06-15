defmodule OpenMesWeb.Admin.ReportsLiveTest do
  @moduledoc """
  G5 조회/대시보드 + G6 관리자 LiveView 기본 테스트.

    - 각 조회 화면(생산현황/공정별실적/불량현황/재고흐름/LOT이력)이 200 으로 렌더.
    - 빈 데이터 방어(빈 상태 안내 노출, 0 나눗셈 없음).
    - 집계 정확성(작업지시 상태별 건수, 공정별 양품/불량, 불량 유형별 수량).
    - 감사로그 조회 + resource_type/actor 필터.
    - 사용자/권한 화면이 Worker 를 사용자로 표시.

  모든 화면은 읽기 전용(쓰기 없음). 세션 actor 미지정이어도 AdminLive on_mount 가
  기본 actor("admin")를 주입한다(MVP).
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenMes.Lots
  alias OpenMes.MasterData
  alias OpenMes.Production
  alias OpenMes.Production.Reports
  alias OpenMes.Lots.Reports, as: LotsReports

  # ──────────────────────────────────────────────────────────────────
  # 시드 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp seed_item(code, type \\ "product") do
    {:ok, item} =
      MasterData.create_item(
        %{"item_code" => code, "name" => "테스트#{code}", "item_type" => type, "unit" => "EA"},
        "seed"
      )

    item
  end

  defp seed_process(code) do
    {:ok, p} = MasterData.create_process(%{"process_code" => code, "name" => "공정#{code}"}, "seed")
    p
  end

  defp seed_work_order(item, status \\ "draft") do
    {:ok, wo} =
      Production.create_work_order(
        %{
          "work_order_no" => "WO-#{System.unique_integer([:positive])}",
          "item_id" => item.id,
          "planned_quantity" => "100"
        },
        "seed"
      )

    advance_status(wo, status)
  end

  defp advance_status(wo, "draft"), do: wo

  defp advance_status(wo, "released") do
    {:ok, wo} = Production.release_work_order(wo.id, "seed")
    wo
  end

  defp advance_status(wo, "completed") do
    {:ok, _} = Production.release_work_order(wo.id, "seed")
    {:ok, _} = Production.start_work_order(wo.id, "seed")
    {:ok, wo} = Production.complete_work_order(wo.id, "seed")
    wo
  end

  defp seed_operation(wo, process, seq) do
    {:ok, op} =
      Production.create_operation(
        %{"work_order_id" => wo.id, "process_id" => process.id, "sequence" => seq},
        "seed"
      )

    op
  end

  defp seed_result(op, good, defect) do
    {:ok, r} =
      Production.create_production_result(
        %{"operation_id" => op.id, "good_quantity" => good, "defect_quantity" => defect},
        "seed"
      )

    r
  end

  defp seed_defect(result, code, qty) do
    {:ok, d} =
      Production.record_defect(
        %{"production_result_id" => result.id, "defect_code" => code, "quantity" => qty},
        "seed"
      )

    d
  end

  # ──────────────────────────────────────────────────────────────────
  # G5 - 빈 데이터 방어 (스모크)
  # ──────────────────────────────────────────────────────────────────

  describe "빈 데이터 방어" do
    test "생산 대시보드 — 빈 데이터에서 200 + SVG 위젯 + 빈 상태 무붕괴", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")
      assert html =~ "생산 대시보드"
      # 외부 차트 라이브러리 없이 순수 SVG 위젯이 다수 노출된다.
      assert html =~ "<svg"
      # KPI/도넛/게이지 라벨.
      assert html =~ "오늘 생산량"
      assert html =~ "작업지시 상태 분포"
      assert html =~ "종합 불량률"
      # 빈 데이터에서 W4/W6 는 빈 상태로 자연 축소(레이아웃 무붕괴).
      assert html =~ "진행중 작업지시가 없습니다"
      assert html =~ "공정 실적이 없습니다"
    end

    test "공장 생산라인 모니터 — 빈 데이터(P-라인 공정 없음)에서 200 + 빈 상태 안내", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/reports/production")
      assert html =~ "공장 생산라인 모니터"
      # 사출 라인 공정(P01~P10)이 없으면 빈 상태 안내(무붕괴).
      assert html =~ "등록된 생산라인 공정이 없습니다"
    end

    test "불량 현황 — 빈 데이터에서 200 + 불량률 0%(0 나눗셈 방어)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/reports/defects")
      assert html =~ "불량 현황"
      assert html =~ "0.00%"
      assert html =~ "집계할 불량 기록이 없습니다"
    end

    test "재고 흐름 — 빈 데이터에서 200 + 빈 상태 안내", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/reports/inventory")
      assert html =~ "재고 흐름"
      assert html =~ "집계할 품목별 LOT 가 없습니다"
    end

    test "LOT 이력 — 빈 데이터에서 200 + 빈 상태 안내", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/reports/lots")
      assert html =~ "LOT 이력 조회"
      assert html =~ "조회된 LOT 가 없습니다"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # G5 - 집계 정확성
  # ──────────────────────────────────────────────────────────────────

  describe "생산 현황 집계" do
    test "작업지시 상태별 건수가 정확히 집계된다", %{conn: conn} do
      item = seed_item("ITM-DASH")
      seed_work_order(item, "draft")
      seed_work_order(item, "draft")
      seed_work_order(item, "released")
      seed_work_order(item, "completed")

      counts = Reports.work_order_status_counts()
      assert counts.total == 4
      assert counts["draft"] == 2
      assert counts["released"] == 1
      assert counts["completed"] == 1
      assert counts["cancelled"] == 0

      {:ok, _view, html} = live(conn, "/admin/dashboard")
      # 대시보드는 표가 아닌 SVG 도넛 차트로 작업지시 상태 분포를 시각화한다.
      assert html =~ "작업지시 상태 분포"
      # 세그먼트(상태별 path)와 범례 라벨이 렌더된다.
      assert html =~ "<path"
      assert html =~ "작성중"
      assert html =~ "완료"
      # 도넛 중앙 total 텍스트(4건) — 들여쓰기/개행을 무시하고 매칭한다.
      assert Regex.match?(~r/<text[^>]*>\s*4\s*<\/text>/, html)
      # 범례 수량: 작성중 2건이 표기된다(>2</span> 형태).
      assert html =~ ">2</span>"
    end
  end

  describe "공정별 실적 집계" do
    test "공정별 양품/불량이 합산되고 라인 모니터에 공정 노드가 표시된다", %{conn: conn} do
      item = seed_item("ITM-PROC")
      wo = seed_work_order(item)
      # 라인 모니터는 라인 구성(ProductionLine)이 표시 공정을 정의한다(설계 22번 — 정규식 제거).
      proc = seed_process("P01")
      {:ok, line} = OpenMes.ProductionLine.create_line(%{line_code: "LINE-T", name: "테스트 라인"}, "test")
      {:ok, _} = OpenMes.ProductionLine.create_step(%{line_id: line.id, process_id: proc.id, sequence: 1}, "test")
      op = seed_operation(wo, proc, 1)
      seed_result(op, "10", "2")
      seed_result(op, "5", "1")

      [row] = Reports.production_by_process()
      assert row.process_id == proc.id
      assert Decimal.equal?(row.good_quantity, Decimal.new(15))
      assert Decimal.equal?(row.defect_quantity, Decimal.new(3))
      assert Decimal.equal?(row.total, Decimal.new(18))
      assert row.result_count == 2

      {:ok, _view, html} = live(conn, "/admin/reports/production")
      # 라인 모니터(SVG) + 해당 공정 노드(P01) + 상세 표가 렌더된다.
      assert html =~ "공장 생산라인 모니터"
      assert html =~ "<svg"
      assert html =~ "P01"
    end
  end

  describe "불량 현황 집계" do
    test "불량 유형별 수량 합산 + 기간 요약 불량률", %{conn: conn} do
      item = seed_item("ITM-DEF")
      wo = seed_work_order(item)
      proc = seed_process("PC-D")
      op = seed_operation(wo, proc, 1)
      r1 = seed_result(op, "8", "2")
      seed_defect(r1, "SCRATCH", "2")
      r2 = seed_result(op, "0", "3")
      seed_defect(r2, "CRACK", "3")

      defects = Reports.defects_by_code()
      by_code = Map.new(defects, fn d -> {d.defect_code, d.quantity} end)
      assert Decimal.equal?(by_code["SCRATCH"], Decimal.new(2))
      assert Decimal.equal?(by_code["CRACK"], Decimal.new(3))

      summary = Reports.defect_summary()
      # good 8, defect 5, total 13 → defect_rate ≈ 0.3846
      assert Decimal.equal?(summary.good_quantity, Decimal.new(8))
      assert Decimal.equal?(summary.defect_quantity, Decimal.new(5))
      assert_in_delta summary.defect_rate, 5 / 13, 0.0001

      {:ok, _view, html} = live(conn, "/admin/reports/defects")
      assert html =~ "SCRATCH"
      assert html =~ "CRACK"
    end
  end

  describe "재고 흐름 집계" do
    test "품목별 보유/소비 흐름이 집계된다", %{conn: conn} do
      raw = seed_item("ITM-RAW", "raw")
      prod = seed_item("ITM-PRD", "product")

      # 원자재 LOT 입고 100, 제품 LOT 생성(produced)
      {:ok, raw_lot} =
        Lots.receive_lot(
          %{"lot_no" => "LOT-RAW-1", "item_id" => raw.id, "lot_type" => "raw", "quantity" => "100"},
          "seed"
        )

      wo = seed_work_order(prod)
      proc = seed_process("PC-INV")
      op = seed_operation(wo, proc, 1)

      # 원자재 30 소비
      {:ok, _} = Lots.consume_lot(op.id, raw_lot.id, "30", "seed")

      flow = LotsReports.inventory_flow_by_item()
      raw_row = Enum.find(flow, &(&1.item_id == raw.id))
      assert raw_row
      # 보유 잔량: 100 - 30 = 70
      assert Decimal.equal?(raw_row.on_hand_quantity, Decimal.new(70))
      # 소비: 30
      assert Decimal.equal?(raw_row.consumed_quantity, Decimal.new(30))

      status_dist = LotsReports.lots_by_status()
      assert is_list(status_dist)

      {:ok, _view, html} = live(conn, "/admin/reports/inventory")
      assert html =~ "ITM-RAW"
    end
  end

  describe "LOT 이력 조회" do
    test "LOT 목록이 렌더되고 상태/계보 링크가 표시된다", %{conn: conn} do
      item = seed_item("ITM-LOT", "raw")

      {:ok, _lot} =
        Lots.receive_lot(
          %{"lot_no" => "LOT-HIST-1", "item_id" => item.id, "lot_type" => "raw", "quantity" => "50"},
          "seed"
        )

      {:ok, _view, html} = live(conn, "/admin/reports/lots")
      assert html =~ "LOT-HIST-1"
      assert html =~ "계보 보기"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # G6 - 관리자
  # ──────────────────────────────────────────────────────────────────

  describe "감사 로그 조회" do
    test "감사 로그 화면이 200 으로 렌더되고 작업 이력이 보인다", %{conn: conn} do
      item = seed_item("ITM-AUD")
      _wo = seed_work_order(item)

      {:ok, _view, html} = live(conn, "/admin/audit-logs")
      assert html =~ "감사 로그"
      # 작업지시 생성 + 품목 생성 AuditLog 가 존재
      assert html =~ "work_order.create"
      assert html =~ "item.create"
    end

    test "resource_type 필터가 동작한다", %{conn: conn} do
      item = seed_item("ITM-AUD2")
      _wo = seed_work_order(item)

      {:ok, view, _html} = live(conn, "/admin/audit-logs")

      html =
        view
        |> form("form[phx-submit=filter]", %{"resource_type" => "item", "actor" => "", "from" => "", "to" => ""})
        |> render_submit()

      assert html =~ "item.create"
      refute html =~ "work_order.create"
    end

    test "actor 필터가 부분일치로 동작한다", %{conn: conn} do
      # actor "seed" 로 품목 생성, actor "kim" 으로 작업지시 생성
      item = seed_item("ITM-AUD3")

      {:ok, _} =
        Production.create_work_order(
          %{"work_order_no" => "WO-ACTOR", "item_id" => item.id, "planned_quantity" => "10"},
          "kim"
        )

      {:ok, view, _html} = live(conn, "/admin/audit-logs")

      html =
        view
        |> form("form[phx-submit=filter]", %{
          "resource_type" => "",
          "actor" => "kim",
          "from" => "",
          "to" => ""
        })
        |> render_submit()

      # kim 의 work_order.create 만 남고, seed 의 item.create 는 걸러진다
      assert html =~ "work_order.create"
      refute html =~ "item.create"
    end

    test "빈 환경에서도 200 + 빈 상태 안내", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/audit-logs")
      assert html =~ "감사 로그"
      assert html =~ "조회된 감사 로그가 없습니다"
    end
  end

  describe "사용자/권한" do
    test "작업자 목록이 사용자로 표시된다", %{conn: conn} do
      {:ok, _w} = MasterData.create_worker(%{"worker_code" => "W-001", "name" => "홍길동"}, "seed")

      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "사용자/권한"
      assert html =~ "W-001"
      assert html =~ "홍길동"
      assert html =~ "현장 작업자"
    end

    test "빈 환경에서도 200 + 안내", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "등록된 작업자가 없습니다"
    end
  end
end
