defmodule OpenMesWeb.AuthorizationTest do
  @moduledoc """
  역할(role) 인가 단일 원천(OpenMesWeb.Authorization) 단위 테스트(설계 §2.2, §3).

    - allowed?/2: system_admin 전체 허용 / 비-admin 자기 화면만 / prefix 매칭 / 현장 영역
    - visible_menu/1: role 별 보이는 메뉴 필터
    - roles_for_path/1: 배지 렌더용 role 리스트(system_admin 항상 포함)
    - landing/1: role 별 랜딩 경로
    - 메타/유효성
  """
  use ExUnit.Case, async: true

  alias OpenMesWeb.Authorization

  describe "메타" do
    test "role 5종 + 한국어명 + 색 클래스" do
      keys = Authorization.role_keys()

      assert keys == [
               "system_admin",
               "production_manager",
               "quality_manager",
               "material_manager",
               "operator"
             ]

      assert Authorization.role_label("production_manager") == "생산관리자"
      assert Authorization.role_badge_class("operator") == "bg-purple-100 text-purple-700"
      assert Authorization.role_badge_class("system_admin") == "bg-slate-100 text-slate-700"
    end

    test "미지 role 은 zinc fallback" do
      meta = Authorization.role("nope")
      assert meta.label == "미지정"
      assert meta.badge_class =~ "zinc"
    end

    test "valid_role?/1" do
      assert Authorization.valid_role?("quality_manager")
      refute Authorization.valid_role?("god")
    end
  end

  describe "allowed?/2" do
    test "system_admin 은 모든 경로 허용" do
      for path <- ["/admin/items", "/admin/users", "/admin/audit-logs", "/shopfloor", "/admin/lots/x/genealogy"] do
        assert Authorization.allowed?("system_admin", path)
      end
    end

    test "production_manager: 기준정보/생산관리/대시보드 허용, LOT·사용자 차단" do
      assert Authorization.allowed?("production_manager", "/admin/items")
      assert Authorization.allowed?("production_manager", "/admin/work-orders")
      assert Authorization.allowed?("production_manager", "/admin/dashboard")
      refute Authorization.allowed?("production_manager", "/admin/lots")
      refute Authorization.allowed?("production_manager", "/admin/users")
      refute Authorization.allowed?("production_manager", "/shopfloor")
    end

    test "operator: 현장만 허용, /admin 차단" do
      assert Authorization.allowed?("operator", "/shopfloor")
      assert Authorization.allowed?("operator", "/shopfloor/operations/123")
      refute Authorization.allowed?("operator", "/admin/items")
      refute Authorization.allowed?("operator", "/admin/work-orders")
    end

    test "material_manager: LOT·재고 허용, 현장/사용자 차단" do
      assert Authorization.allowed?("material_manager", "/admin/lots")
      assert Authorization.allowed?("material_manager", "/admin/reports/inventory")
      refute Authorization.allowed?("material_manager", "/shopfloor")
      refute Authorization.allowed?("material_manager", "/admin/users")
    end

    test "prefix 매칭 — 하위 경로도 동일 인가" do
      assert Authorization.allowed?("production_manager", "/admin/work-orders/abc/operations")
      assert Authorization.allowed?("material_manager", "/admin/lots/abc/genealogy")
    end

    test "사용자/감사 로그는 system_admin 전용" do
      refute Authorization.allowed?("production_manager", "/admin/users")
      refute Authorization.allowed?("quality_manager", "/admin/audit-logs")
      assert Authorization.allowed?("system_admin", "/admin/users")
    end
  end

  describe "roles_for_path/1" do
    test "system_admin 항상 포함" do
      roles = Authorization.roles_for_path("/admin/items")
      assert "system_admin" in roles
      assert "production_manager" in roles
    end

    test "system_admin 전용 화면은 system_admin 만" do
      assert Authorization.roles_for_path("/admin/users") == ["system_admin"]
    end

    test "현장 경로는 operator + system_admin" do
      roles = Authorization.roles_for_path("/shopfloor")
      assert "operator" in roles
      assert "system_admin" in roles
    end
  end

  describe "visible_menu/1" do
    test "system_admin 은 전체 그룹" do
      groups = Authorization.visible_menu("system_admin")
      labels = Enum.map(groups, & &1.group)
      assert "기준정보" in labels
      assert "관리자" in labels
      assert "LOT 추적" in labels
    end

    test "production_manager 는 기준정보/생산관리/조회 보임, LOT추적/관리자 숨김" do
      groups = Authorization.visible_menu("production_manager")
      labels = Enum.map(groups, & &1.group)
      assert "기준정보" in labels
      assert "생산관리" in labels
      assert "조회/대시보드" in labels
      refute "관리자" in labels
      refute "LOT 추적" in labels
    end

    test "operator 는 admin 메뉴가 비어 있다(현장 전용)" do
      groups = Authorization.visible_menu("operator")
      assert groups == []
    end

    test "조회/대시보드 항목별 role 필터 — material_manager 는 재고·LOT이력만" do
      groups = Authorization.visible_menu("material_manager")
      dashboard = Enum.find(groups, &(&1.group == "조회/대시보드"))
      paths = Enum.map(dashboard.items, & &1.path)
      assert "/admin/reports/inventory" in paths
      assert "/admin/reports/lots" in paths
      refute "/admin/reports/defects" in paths
    end
  end

  describe "landing/1" do
    test "operator → /shopfloor" do
      assert Authorization.landing("operator") == "/shopfloor"
    end

    test "production_manager → 첫 허용 화면(/admin/items)" do
      assert Authorization.landing("production_manager") == "/admin/items"
    end

    test "material_manager → /admin/lots" do
      assert Authorization.landing("material_manager") == "/admin/lots"
    end

    test "system_admin → /admin/items" do
      assert Authorization.landing("system_admin") == "/admin/items"
    end
  end
end
