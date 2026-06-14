defmodule OpenMesWeb.Admin.ProductionLiveTest do
  @moduledoc """
  G2 생산관리 LiveView 기본 테스트.

    - 작업지시 목록/상세 화면이 200 으로 렌더된다.
    - 작업지시 생성 폼 제출 → 목록 반영 + work_order.create AuditLog(컨텍스트 동반).
    - 상태 전이(release) → work_order.released AuditLog + Outbox 이벤트.
    - 상태 전이 UI 는 허용 전이만 노출(상태머신 위반 버튼 비노출).
    - 공정 실적 입력 → ProductionResult + 불량수량 입력 시 DefectRecord 연결.

  세션 actor 미지정이어도 AdminLive on_mount 가 기본 actor("admin")를 주입한다(MVP, 설계 §2.5).
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production
  alias OpenMes.Production.{DefectRecord, ProductionResult}
  alias OpenMes.Repo

  defp seed_item(code) do
    {:ok, item} =
      MasterData.create_item(
        %{"item_code" => code, "name" => "테스트품목", "item_type" => "product", "unit" => "EA"},
        "seed"
      )

    item
  end

  defp seed_work_order(item) do
    {:ok, wo} =
      Production.create_work_order(
        %{"work_order_no" => "WO-#{System.unique_integer([:positive])}", "item_id" => item.id, "planned_quantity" => "100"},
        "seed"
      )

    wo
  end

  describe "작업지시 목록/상세 렌더(스모크)" do
    test "작업지시 목록이 200 으로 렌더된다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/work-orders")
      assert html =~ "작업지시 관리"
      # 사이드바 생산관리 메뉴가 활성 링크로 렌더되는지
      assert html =~ "생산관리"
    end

    test "빈 목록은 빈 상태 안내를 보여준다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/work-orders")
      assert html =~ "작업지시가 없습니다"
    end

    test "작업지시 상세가 렌더되고 품목/상태가 표시된다", %{conn: conn} do
      item = seed_item("ITM-SHOW")
      wo = seed_work_order(item)

      {:ok, _view, html} = live(conn, "/admin/work-orders/#{wo.id}")
      assert html =~ wo.work_order_no
      assert html =~ "ITM-SHOW"
      assert html =~ "작성중"
    end
  end

  describe "작업지시 생성 → AuditLog" do
    test "신규 폼 제출 시 작업지시가 생성되고 work_order.create AuditLog 가 남는다", %{conn: conn} do
      item = seed_item("ITM-NEW")
      {:ok, view, _html} = live(conn, "/admin/work-orders/new")

      params = %{
        "work_order_no" => "WO-LV-1",
        "item_id" => item.id,
        "planned_quantity" => "50",
        "due_date" => "2026-07-01"
      }

      html =
        view
        |> form("#wo-modal form", work_order: params)
        |> render_submit()

      assert html =~ "WO-LV-1"

      logs = Repo.all(from a in AuditLog, where: a.action == "work_order.create")
      assert [%AuditLog{resource_type: "work_order", actor_id: "admin"}] = logs
    end
  end

  describe "상태 전이 UI — 허용 전이만 노출" do
    test "draft 작업지시는 release/cancel 버튼만 노출(start/complete 비노출)", %{conn: conn} do
      item = seed_item("ITM-TR")
      wo = seed_work_order(item)

      {:ok, _view, html} = live(conn, "/admin/work-orders/#{wo.id}")

      # draft → released, cancelled 만 허용
      assert html =~ "지시 (release)"
      assert html =~ "취소 (cancel)"
      # 착수/완료는 draft 에서 불가 → 버튼 비노출
      refute html =~ "착수 (start)"
      refute html =~ "완료 (complete)"
    end

    test "release 전이 → 상태 변경 + AuditLog + Outbox 이벤트", %{conn: conn} do
      item = seed_item("ITM-REL")
      wo = seed_work_order(item)

      {:ok, view, _html} = live(conn, "/admin/work-orders/#{wo.id}")

      html =
        view
        |> element("button[phx-value-to=released]")
        |> render_click()

      # 전이 후 진행중 후보 버튼이 나타나고 release 버튼은 사라진다
      assert html =~ "착수 (start)"

      assert Repo.get(OpenMes.Production.WorkOrder, wo.id).status == "released"

      assert Repo.exists?(from a in AuditLog, where: a.action == "work_order.release")
      assert Repo.exists?(from e in Event, where: e.event_type == "work_order.released")
    end
  end

  describe "공정 실적 입력 → ProductionResult + DefectRecord 연결" do
    test "공정 추가 → 실적 등록(불량 0) → ProductionResult 1건, DefectRecord 0건", %{conn: conn} do
      item = seed_item("ITM-OP1")
      wo = seed_work_order(item)
      {:ok, process} = MasterData.create_process(%{"process_code" => "P1", "name" => "조립"}, "seed")

      {:ok, view, _html} = live(conn, "/admin/work-orders/#{wo.id}/operations")

      # 공정 추가
      view
      |> form("form[phx-submit=add_operation]", operation: %{"process_id" => process.id, "sequence" => "1"})
      |> render_submit()

      [op] = Production.list_operations(wo.id)

      # 실적 입력 패널 열기
      view |> element("button[phx-value-id=#{op.id}]", "실적 입력") |> render_click()

      # 양품만 입력(불량 0)
      view
      |> form("form[phx-submit=save_result]",
        result: %{"good_quantity" => "10", "defect_quantity" => "0", "worker_id" => "", "equipment_id" => ""}
      )
      |> render_submit()

      assert [%ProductionResult{good_quantity: g}] = Repo.all(from r in ProductionResult, where: r.operation_id == ^op.id)
      assert Decimal.equal?(g, Decimal.new(10))
      assert Repo.all(DefectRecord) == []

      # production_result.create AuditLog 동반
      assert Repo.exists?(from a in AuditLog, where: a.action == "production_result.create")
    end

    test "불량수량 > 0 입력 시 불량 폼이 뜨고 DefectRecord 가 연결된다", %{conn: conn} do
      item = seed_item("ITM-OP2")
      wo = seed_work_order(item)
      {:ok, process} = MasterData.create_process(%{"process_code" => "P2", "name" => "검사"}, "seed")

      {:ok, view, _html} = live(conn, "/admin/work-orders/#{wo.id}/operations")

      view
      |> form("form[phx-submit=add_operation]", operation: %{"process_id" => process.id, "sequence" => "1"})
      |> render_submit()

      [op] = Production.list_operations(wo.id)
      view |> element("button[phx-value-id=#{op.id}]", "실적 입력") |> render_click()

      # 불량 3 입력 → 불량 상세 폼 노출
      html =
        view
        |> form("form[phx-submit=save_result]",
          result: %{"good_quantity" => "7", "defect_quantity" => "3", "worker_id" => "", "equipment_id" => ""}
        )
        |> render_submit()

      assert html =~ "불량 상세 기록"

      [result] = Repo.all(from r in ProductionResult, where: r.operation_id == ^op.id)

      # 불량 기록 제출
      view
      |> form("form[phx-submit=save_defect]",
        defect: %{"production_result_id" => result.id, "defect_code" => "SCRATCH", "quantity" => "3", "note" => "흠집"}
      )
      |> render_submit()

      assert [%DefectRecord{defect_code: "SCRATCH", production_result_id: prid}] = Repo.all(DefectRecord)
      assert prid == result.id

      # defect.record AuditLog + defect.recorded Outbox 이벤트
      assert Repo.exists?(from a in AuditLog, where: a.action == "defect.record")
      assert Repo.exists?(from e in Event, where: e.event_type == "defect.recorded")
    end
  end
end
