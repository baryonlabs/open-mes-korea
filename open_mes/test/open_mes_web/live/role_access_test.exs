defmodule OpenMesWeb.RoleAccessTest do
  @moduledoc """
  역할(role) 화면 접근 제어 통합 테스트(설계 §3, §4).

    - 비-admin role 로 비허용 URL 직접 진입 → 차단(landing 리다이렉트 + flash)
    - system_admin 은 전체 화면 접근
    - 사이드바 가시성: 비-admin 은 자기 화면만(허용 메뉴), 비허용 메뉴 숨김
    - role_badge 렌더(사용자/권한 화면 — Worker.role 색 배지)
    - role 전환 컨트롤러(/session/role/:role)
  """
  use OpenMesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenMes.MasterData

  # 세션 current_role 을 주입한 conn.
  defp with_role(conn, role) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:current_role, role)
  end

  describe "직접 URL 인가(비-admin 차단)" do
    test "production_manager 가 /admin/lots 직접 진입 시 차단·리다이렉트", %{conn: conn} do
      conn = with_role(conn, "production_manager")

      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, "/admin/lots")
      assert to == "/admin/items"
      assert flash["error"] =~ "접근할 권한이 없습니다"
      assert flash["error"] =~ "생산관리자"
    end

    test "production_manager 가 /admin/users(전용) 직접 진입 시 차단", %{conn: conn} do
      conn = with_role(conn, "production_manager")
      assert {:error, {:redirect, %{to: "/admin/items"}}} = live(conn, "/admin/users")
    end

    test "material_manager 가 /admin/work-orders 직접 진입 시 차단", %{conn: conn} do
      conn = with_role(conn, "material_manager")
      assert {:error, {:redirect, %{to: to}}} = live(conn, "/admin/work-orders")
      assert to == "/admin/lots"
    end

    test "operator 가 /admin/items 직접 진입 시 현장으로 리다이렉트", %{conn: conn} do
      conn = with_role(conn, "operator")
      assert {:error, {:redirect, %{to: "/shopfloor"}}} = live(conn, "/admin/items")
    end
  end

  describe "허용 URL 접근" do
    test "production_manager 는 /admin/items 접근 가능", %{conn: conn} do
      conn = with_role(conn, "production_manager")
      assert {:ok, _view, _html} = live(conn, "/admin/items")
    end

    test "material_manager 는 /admin/lots 접근 가능", %{conn: conn} do
      conn = with_role(conn, "material_manager")
      assert {:ok, _view, _html} = live(conn, "/admin/lots")
    end
  end

  describe "system_admin 전체 접근" do
    test "system_admin 은 모든 화면 접근(샘플 다수)", %{conn: conn} do
      conn = with_role(conn, "system_admin")

      for path <- ["/admin/items", "/admin/lots", "/admin/work-orders", "/admin/users", "/admin/audit-logs"] do
        assert {:ok, _view, _html} = live(conn, path), "#{path} 접근 실패"
      end
    end

    test "세션 role 없으면 기본 system_admin 으로 전체 접근", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/admin/users")
    end
  end

  describe "사이드바 가시성" do
    test "system_admin 사이드바에 전체 그룹 + role 색 점", %{conn: conn} do
      conn = with_role(conn, "system_admin")
      {:ok, _view, html} = live(conn, "/admin/items")

      assert html =~ "기준정보"
      assert html =~ "LOT 추적"
      assert html =~ "관리자"
      # role 색 점(slate dot 등) — system_admin 일 때만 표시
      assert html =~ "bg-blue-500" or html =~ "bg-slate-500"
    end

    test "production_manager 사이드바에 LOT추적/관리자 그룹 숨김", %{conn: conn} do
      conn = with_role(conn, "production_manager")
      {:ok, _view, html} = live(conn, "/admin/items")

      assert html =~ "기준정보"
      assert html =~ "생산관리"
      refute html =~ "LOT 추적"
      # 관리자 그룹 항목(사용자/권한)은 사이드바에 없어야
      refute html =~ ">사용자/권한<"
    end
  end

  describe "role 배지 렌더(UserLive)" do
    test "사용자 목록에 Worker.role 색 배지가 보인다", %{conn: conn} do
      {:ok, _} = MasterData.create_worker(%{worker_code: "WT-PM", name: "테스트PM", role: "production_manager"}, "test")
      {:ok, _} = MasterData.create_worker(%{worker_code: "WT-OP", name: "테스트OP", role: "operator"}, "test")

      conn = with_role(conn, "system_admin")
      {:ok, _view, html} = live(conn, "/admin/users")

      assert html =~ "생산관리자"
      assert html =~ "현장 작업자"
      assert html =~ "bg-blue-100"
      assert html =~ "bg-purple-100"
    end
  end

  describe "role 전환 컨트롤러" do
    test "유효 role POST → 세션 기록 + landing 리다이렉트", %{conn: conn} do
      conn = post(conn, "/session/role/production_manager")
      assert redirected_to(conn) == "/admin/items"
      assert Plug.Conn.get_session(conn, :current_role) == "production_manager"
    end

    test "operator 전환 → /shopfloor 로", %{conn: conn} do
      conn = post(conn, "/session/role/operator")
      assert redirected_to(conn) == "/shopfloor"
      assert Plug.Conn.get_session(conn, :current_role) == "operator"
    end

    test "잘못된 role 은 세션 기록 안 함", %{conn: conn} do
      conn = post(conn, "/session/role/god")
      assert Plug.Conn.get_session(conn, :current_role) == nil
    end
  end
end
