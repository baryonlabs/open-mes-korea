defmodule OpenMesWeb.Admin.MasterDataLiveTest do
  @moduledoc """
  G1 기준정보 관리 LiveView 기본 테스트.

    - 6종 목록 화면이 200 으로 렌더된다(빈 상태 안내 포함).
    - 품목 생성 폼 제출 → 목록에 반영 + item.create AuditLog 1건(컨텍스트 동반).
    - 활성 토글 → item.update AuditLog.
    - BOM/라우팅: 선행 기준정보 없을 때 빈 상태 안내(의존 데이터 가드).

  세션 actor 미지정이어도 AdminLive on_mount 가 기본 actor("admin")를 주입하므로
  로그인 없이 검증한다(MVP 간이 인증 — 설계 §2.5).
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.MasterData.Item
  alias OpenMes.Repo

  describe "목록 렌더(스모크)" do
    test "6종 기준정보 목록이 모두 렌더된다", %{conn: conn} do
      for {path, title} <- [
            {"/admin/items", "품목 관리"},
            {"/admin/boms", "BOM 관리"},
            {"/admin/processes", "공정 관리"},
            {"/admin/routings", "라우팅 관리"},
            {"/admin/equipment", "설비 관리"},
            {"/admin/workers", "작업자 관리"}
          ] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ title
        # 사이드바 공통 네비게이션이 함께 렌더되는지
        assert html =~ "기준정보"
      end
    end

    test "빈 목록은 빈 상태 안내를 보여준다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/items")
      assert html =~ "등록된 품목이 없습니다"
    end
  end

  describe "품목 생성 폼 → AuditLog" do
    test "신규 폼 제출 시 품목이 생성되고 item.create AuditLog 가 남는다", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/items/new")

      params = %{
        "item_code" => "ITM-LV-1",
        "name" => "라이브뷰품목",
        "item_type" => "product",
        "unit" => "EA",
        "active" => "true"
      }

      html =
        view
        |> form("#item-modal form", item: params)
        |> render_submit()

      # push_patch 후 목록에 새 품목이 보인다
      assert html =~ "ITM-LV-1"
      assert html =~ "라이브뷰품목"

      # 컨텍스트가 AuditLog 를 동반했는지(LiveView 가 직접 만들지 않음)
      logs = Repo.all(AuditLog)
      assert [%AuditLog{action: "item.create", resource_type: "item", actor_id: "admin"}] = logs
    end

    test "유효성 위반(중복 코드) 시 폼에 에러를 표시한다", %{conn: conn} do
      {:ok, _} = MasterData.create_item(%{"item_code" => "DUP", "name" => "기존", "item_type" => "raw", "unit" => "EA"}, "seed")

      {:ok, view, _html} = live(conn, "/admin/items/new")

      html =
        view
        |> form("#item-modal form",
          item: %{"item_code" => "DUP", "name" => "중복", "item_type" => "raw", "unit" => "EA"}
        )
        |> render_submit()

      assert html =~ "이미 존재하는 품목 코드입니다"
    end
  end

  describe "활성 토글 → AuditLog" do
    test "토글 시 비활성화되고 item.update AuditLog 가 남는다", %{conn: conn} do
      {:ok, item} =
        MasterData.create_item(
          %{"item_code" => "TGL-1", "name" => "토글품목", "item_type" => "raw", "unit" => "EA"},
          "seed"
        )

      {:ok, view, _html} = live(conn, "/admin/items")

      view
      |> element("button[phx-value-id='#{item.id}']", "비활성")
      |> render_click()

      assert Repo.get(Item, item.id).active == false

      assert Repo.exists?(
               from(l in AuditLog, where: l.action == "item.update" and l.resource_id == ^item.id)
             )
    end
  end

  describe "의존 데이터 가드" do
    test "품목이 없으면 BOM 화면은 품목 등록을 안내한다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/boms")
      assert html =~ "먼저 품목이 필요합니다"
      refute html =~ "신규 BOM"
    end

    test "품목/공정이 없으면 라우팅 화면은 등록을 안내한다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/routings")
      assert html =~ "품목과 공정이 모두 필요합니다"
    end
  end
end
