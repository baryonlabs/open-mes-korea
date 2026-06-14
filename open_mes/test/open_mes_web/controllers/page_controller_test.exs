defmodule OpenMesWeb.PageControllerTest do
  use OpenMesWeb.ConnCase

  # 루트(/)는 MES 생산현황 대시보드로 리다이렉트한다. 확장 카탈로그는 /extensions.
  test "GET / redirects to dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/admin/dashboard"
  end
end
