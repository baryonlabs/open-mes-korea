defmodule OpenMesWeb.SessionController do
  @moduledoc """
  세션 역할(role) 전환 컨트롤러 — 데모용(설계 §4.4).

  LiveView 는 세션을 직접 쓸 수 없으므로 role 전환은 일반 컨트롤러를 경유한다.
  유효 role 만 세션(`:current_role`)에 기록하고, 직전 화면(referer)으로 돌려보낸다.
  본격 RBAC/로그인 아님(pi) — current_role 은 actor 와 독립된 데모 전환 값.
  """
  use OpenMesWeb, :controller

  alias OpenMesWeb.Authorization

  @doc "역할 전환: 유효하면 세션에 기록. 그 후 referer(없으면 /admin/items)로 redirect."
  def set_role(conn, %{"role" => role}) do
    conn =
      if Authorization.valid_role?(role) do
        conn
        |> put_session(:current_role, role)
        |> put_flash(:info, "역할을 전환했습니다: #{Authorization.role_label(role)}")
      else
        put_flash(conn, :error, "알 수 없는 역할입니다.")
      end

    redirect(conn, to: back_path(conn, role))
  end

  # 전환한 role 의 landing 으로 보낸다(현재 화면이 새 role 에 비허용일 수 있으므로 안전).
  defp back_path(_conn, role) do
    if Authorization.valid_role?(role), do: Authorization.landing(role), else: "/admin/items"
  end
end
