defmodule OpenMesWeb.Admin.LotsLiveTest do
  @moduledoc """
  G3 LOT 추적 LiveView 기본 테스트.

    - 자재 LOT 등록(receive_lot → available) → 목록 반영 + AuditLog.
    - LOT 투입(consume_lot) → LotConsumption 1건 + lot.consume AuditLog + 잔량 차감.
    - 초과소비 차단(UI 방어 + 컨텍스트 차단).
    - 제품 LOT 생성(produce_lot) → produced + source_operation_id 연결 + Outbox 이벤트.
    - LOT 계보(genealogy) 화면 렌더 — 제품 LOT → 투입 원자재 LOT 표시.

  세션 actor 미지정이어도 AdminLive on_mount 가 기본 actor("admin")를 주입한다(MVP).
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias OpenMes.Audit.AuditLog
  alias OpenMes.Lots
  alias OpenMes.Lots.{LotConsumption, MaterialLot}
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production
  alias OpenMes.Repo

  @actor "admin"

  defp seed_item(code, type) do
    {:ok, item} =
      MasterData.create_item(
        %{"item_code" => code, "name" => "테스트#{code}", "item_type" => type, "unit" => "EA"},
        "seed"
      )

    item
  end

  defp seed_operation(item) do
    {:ok, wo} =
      Production.create_work_order(
        %{"work_order_no" => "WO-#{System.unique_integer([:positive])}", "item_id" => item.id, "planned_quantity" => "100"},
        "seed"
      )

    {:ok, proc} =
      MasterData.create_process(%{"process_code" => "P-#{System.unique_integer([:positive])}", "name" => "조립"}, "seed")

    {:ok, op} =
      Production.create_operation(%{"work_order_id" => wo.id, "process_id" => proc.id, "sequence" => 1}, "seed")

    op
  end

  describe "LOT 목록/등록" do
    test "LOT 추적 화면이 200 으로 렌더되고 사이드바 메뉴가 활성", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/lots")
      assert html =~ "LOT 추적"
      assert html =~ "자재 LOT"
    end

    test "자재 LOT 등록 → 목록 반영 + AuditLog(material_lot.receive)", %{conn: conn} do
      item = seed_item("RAW-LV", "raw")
      {:ok, view, _html} = live(conn, "/admin/lots")

      view |> element("button", "자재 LOT 등록") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_receive]",
          lot: %{"lot_no" => "LOT-LV-1", "item_id" => item.id, "lot_type" => "raw", "quantity" => "100"}
        )
        |> render_submit()

      assert html =~ "LOT-LV-1"
      assert [%MaterialLot{status: "available"}] = Repo.all(from l in MaterialLot, where: l.lot_no == "LOT-LV-1")
      assert Repo.exists?(from a in AuditLog, where: a.action == "material_lot.receive")
    end
  end

  describe "LOT 투입(consume_lot → LotConsumption)" do
    test "투입 → LotConsumption 1건 + lot.consume AuditLog + Outbox + 잔량 차감", %{conn: conn} do
      raw = seed_item("RAW-C", "raw")
      op = seed_operation(seed_item("PRD-C", "product"))

      {:ok, lot} =
        Lots.receive_lot(%{"lot_no" => "LOT-C-1", "item_id" => raw.id, "lot_type" => "raw", "quantity" => "50"}, @actor)

      {:ok, view, _html} = live(conn, "/admin/lots")
      view |> element("button", "LOT 투입") |> render_click()

      view
      |> form("form[phx-submit=save_consume]",
        consume: %{"operation_id" => op.id, "input_lot_id" => lot.id, "quantity" => "20"}
      )
      |> render_submit()

      assert [%LotConsumption{quantity: q}] = Repo.all(from c in LotConsumption, where: c.operation_id == ^op.id)
      assert Decimal.equal?(q, Decimal.new(20))

      # 잔량 차감(50 - 20 = 30)
      assert Decimal.equal?(Repo.get(MaterialLot, lot.id).quantity, Decimal.new(30))

      assert Repo.exists?(from a in AuditLog, where: a.action == "lot.consume")
      assert Repo.exists?(from e in Event, where: e.event_type == "material_lot.consumed")
    end

    test "초과소비 → 차단(LotConsumption 미생성, 에러 플래시)", %{conn: conn} do
      raw = seed_item("RAW-OVER", "raw")
      op = seed_operation(seed_item("PRD-OVER", "product"))

      {:ok, lot} =
        Lots.receive_lot(%{"lot_no" => "LOT-OVER", "item_id" => raw.id, "lot_type" => "raw", "quantity" => "10"}, @actor)

      {:ok, view, _html} = live(conn, "/admin/lots")
      view |> element("button", "LOT 투입") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_consume]",
          consume: %{"operation_id" => op.id, "input_lot_id" => lot.id, "quantity" => "999"}
        )
        |> render_submit()

      assert html =~ "초과"
      assert Repo.all(from c in LotConsumption, where: c.input_lot_id == ^lot.id) == []
    end
  end

  describe "제품 LOT 생성(produce_lot)" do
    test "생성 → produced + source_operation_id 연결 + Outbox(material_lot.produced)", %{conn: conn} do
      prod = seed_item("PRD-P", "product")
      op = seed_operation(prod)

      {:ok, view, _html} = live(conn, "/admin/lots")
      view |> element("button", "제품 LOT 생성") |> render_click()

      view
      |> form("form[phx-submit=save_produce]",
        produce: %{
          "lot_no" => "LOT-P-1",
          "item_id" => prod.id,
          "lot_type" => "product",
          "quantity" => "30",
          "source_operation_id" => op.id
        }
      )
      |> render_submit()

      assert [%MaterialLot{status: "produced", source_operation_id: src}] =
               Repo.all(from l in MaterialLot, where: l.lot_no == "LOT-P-1")

      assert src == op.id
      assert Repo.exists?(from e in Event, where: e.event_type == "material_lot.produced")
    end
  end

  describe "LOT 계보(genealogy) 조회" do
    test "제품 LOT 계보 화면에 투입 원자재 LOT 이 표시된다", %{conn: conn} do
      raw = seed_item("RAW-G", "raw")
      prod = seed_item("PRD-G", "product")
      op = seed_operation(prod)

      {:ok, raw_lot} =
        Lots.receive_lot(%{"lot_no" => "RAWLOT-G", "item_id" => raw.id, "lot_type" => "raw", "quantity" => "100"}, @actor)

      # 원자재를 공정에 투입
      {:ok, _} = Lots.consume_lot(op.id, raw_lot.id, "40", @actor)

      # 그 공정에서 제품 LOT 생성(계보 연결)
      {:ok, prod_lot} =
        Lots.produce_lot(
          %{"lot_no" => "PRDLOT-G", "item_id" => prod.id, "lot_type" => "product", "quantity" => "40", "source_operation_id" => op.id},
          @actor
        )

      {:ok, _view, html} = live(conn, "/admin/lots/#{prod_lot.id}/genealogy")

      assert html =~ "PRDLOT-G"
      # 계보에 투입된 원자재 LOT 노출
      assert html =~ "RAWLOT-G"
    end
  end
end
