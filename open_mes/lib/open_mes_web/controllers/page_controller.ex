defmodule OpenMesWeb.PageController do
  use OpenMesWeb, :controller

  def home(conn, _params) do
    # 로그인했으면 생산현황 대시보드, 아니면 로그인 페이지로. 확장 카탈로그는 /extensions.
    if get_session(conn, :actor_id) do
      redirect(conn, to: "/admin/dashboard")
    else
      redirect(conn, to: "/login")
    end
  end
end
