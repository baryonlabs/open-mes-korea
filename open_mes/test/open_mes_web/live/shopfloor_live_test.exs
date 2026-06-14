defmodule OpenMesWeb.ShopfloorLiveTest do
  @moduledoc """
  G4 현장 화면 LiveView 기본 테스트.

    - /shopfloor 오늘 작업 목록 200 렌더(현장 레이아웃).
    - 작업 상세 시작(start_operation → running) + AuditLog + Outbox(operation.started).
    - 실적 입력(ProductionResult) — append-only.
    - LOT 스캔 → consume_lot 투입(LotConsumption).

  세션 actor 미지정이어도 ShopfloorLive on_mount 가 기본 actor("shopfloor")를 주입한다(MVP).
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias OpenMes.Audit.AuditLog
  alias OpenMes.Lots
  alias OpenMes.Lots.LotConsumption
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production
  alias OpenMes.Production.{Operation, ProductionResult}
  alias OpenMes.Repo

  @actor "shopfloor"

  defp seed_running_op do
    {:ok, item} =
      MasterData.create_item(
        %{"item_code" => "ITM-SF-#{System.unique_integer([:positive])}", "name" => "현장품목", "item_type" => "product", "unit" => "EA"},
        "seed"
      )

    {:ok, wo} =
      Production.create_work_order(
        %{"work_order_no" => "WO-SF-#{System.unique_integer([:positive])}", "item_id" => item.id, "planned_quantity" => "100"},
        "seed"
      )

    # 작업지시를 released → in_progress 로(오늘 작업 노출 조건)
    {:ok, _} = Production.release_work_order(wo.id, "seed")
    {:ok, _} = Production.start_work_order(wo.id, "seed")

    {:ok, proc} =
      MasterData.create_process(%{"process_code" => "PSF-#{System.unique_integer([:positive])}", "name" => "조립"}, "seed")

    {:ok, op} =
      Production.create_operation(%{"work_order_id" => wo.id, "process_id" => proc.id, "sequence" => 1}, "seed")

    %{item: item, wo: wo, op: op}
  end

  describe "오늘 작업" do
    test "/shopfloor 가 200 으로 렌더된다(현장 레이아웃)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shopfloor")
      assert html =~ "오늘 작업"
    end

    test "진행 중 작업지시의 공정이 카드로 노출된다", %{conn: conn} do
      %{wo: wo} = seed_running_op()
      {:ok, _view, html} = live(conn, "/shopfloor")
      assert html =~ wo.work_order_no
      assert html =~ "공정 1"
    end

    test "현장 상단바에 역할 전환 링크가 노출된다(lockout 방지)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shopfloor")

      # 역할 전환은 POST /session/role/:role 로 동작 — 모든 role 링크가 닿아야
      # operator 등으로 전환했어도 system_admin 으로 되돌릴 수 있다.
      assert html =~ "/session/role/operator"
      assert html =~ "/session/role/system_admin"
      assert html =~ "역할 전환"
    end

    test "현장 상단바에 'Open MES Korea' 브랜드가 노출된다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shopfloor")
      assert html =~ "Open MES Korea"
    end
  end

  describe "작업 상세 — 상태 전이" do
    test "pending 공정은 준비/건너뛰기 버튼만 노출(시작 비노출)", %{conn: conn} do
      %{op: op} = seed_running_op()
      {:ok, _view, html} = live(conn, "/shopfloor/operations/#{op.id}")
      assert html =~ "준비"
      assert html =~ "건너뛰기"
      refute html =~ "작업 시작"
    end

    test "ready → start(running) → AuditLog + Outbox(operation.started)", %{conn: conn} do
      %{op: op} = seed_running_op()
      {:ok, _} = Production.ready_operation(op.id, "seed")

      {:ok, view, _html} = live(conn, "/shopfloor/operations/#{op.id}")

      view |> element("button[phx-value-to=running]") |> render_click()

      assert Repo.get(Operation, op.id).status == "running"
      assert Repo.exists?(from a in AuditLog, where: a.action == "operation.start")
      assert Repo.exists?(from e in Event, where: e.event_type == "operation.started")
    end
  end

  describe "실적 입력" do
    test "양품 입력 → ProductionResult 1건(append-only) + AuditLog", %{conn: conn} do
      %{op: op} = seed_running_op()
      {:ok, view, _html} = live(conn, "/shopfloor/operations/#{op.id}/result")

      view
      |> form("form[phx-submit=save]", result: %{"good_quantity" => "12", "defect_quantity" => "0", "defect_code" => ""})
      |> render_submit()

      assert [%ProductionResult{good_quantity: g}] = Repo.all(from r in ProductionResult, where: r.operation_id == ^op.id)
      assert Decimal.equal?(g, Decimal.new(12))
      assert Repo.exists?(from a in AuditLog, where: a.action == "production_result.create")
    end
  end

  describe "LOT 스캔 투입" do
    test "LOT 스캔 → 투입(consume_lot) → LotConsumption 생성", %{conn: conn} do
      %{op: op} = seed_running_op()

      {:ok, raw_item} =
        MasterData.create_item(
          %{"item_code" => "RAW-SCAN-#{System.unique_integer([:positive])}", "name" => "원자재", "item_type" => "raw", "unit" => "kg"},
          "seed"
        )

      {:ok, lot} =
        Lots.receive_lot(%{"lot_no" => "SCANLOT-1", "item_id" => raw_item.id, "lot_type" => "raw", "quantity" => "80"}, @actor)

      {:ok, view, _html} = live(conn, "/shopfloor/scan?operation_id=#{op.id}")

      # LOT 번호 스캔
      html = view |> form("form[phx-submit=scan]", %{"lot_no" => "SCANLOT-1"}) |> render_submit()
      assert html =~ "SCANLOT-1"
      assert html =~ "잔량"

      # 투입 수량 제출
      view |> form("form[phx-submit=consume]", %{"quantity" => "25"}) |> render_submit()

      assert [%LotConsumption{quantity: q}] = Repo.all(from c in LotConsumption, where: c.input_lot_id == ^lot.id)
      assert Decimal.equal?(q, Decimal.new(25))
    end
  end
end
