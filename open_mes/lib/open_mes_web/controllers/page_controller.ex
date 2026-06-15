defmodule OpenMesWeb.PageController do
  use OpenMesWeb, :controller

  def home(conn, _params) do
    # 루트(/)는 MES 생산현황 대시보드로 진입한다. 확장 카탈로그는 /extensions.
    redirect(conn, to: "/admin/dashboard")
  end
end
