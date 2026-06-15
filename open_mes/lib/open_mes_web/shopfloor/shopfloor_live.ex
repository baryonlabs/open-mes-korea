defmodule OpenMesWeb.Shopfloor.ShopfloorLive do
  @moduledoc """
  현장(/shopfloor) LiveView 공통 베이스 (설계 §2.1 결정2, §2.3).

  `use OpenMesWeb.Shopfloor.ShopfloorLive` 한 줄로:
    - `:shopfloor` 레이아웃 적용(admin 사이드바와 다른 단순 현장 레이아웃)
    - core_components / shopfloor_components import
    - 세션 actor 주입 on_mount 훅 부착

  현장은 대형 버튼·큰 글씨·최소 입력의 태블릿 UX. AdminLive 와 동일하게
  세션 actor 가 없으면 MVP 기본값("shopfloor")으로 대체한다(로그인/RBAC 후속).
  """
  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView, layout: {OpenMesWeb.Layouts, :shopfloor}

      on_mount {OpenMesWeb.Shopfloor.ShopfloorLive, :assign_shopfloor_context}

      import Phoenix.HTML
      import OpenMesWeb.CoreComponents
      import OpenMesWeb.ShopfloorComponents
      import OpenMesWeb.Gettext

      alias Phoenix.LiveView.JS

      use Phoenix.VerifiedRoutes,
        endpoint: OpenMesWeb.Endpoint,
        router: OpenMesWeb.Router,
        statics: OpenMesWeb.static_paths()
    end
  end

  import Phoenix.Component

  alias OpenMesWeb.Authorization

  @doc """
  on_mount 훅: 세션 actor(MVP 간이) + role 주입 + 현장 인가(설계 §3.3).

  세션에 actor_id 가 없으면 MVP 기본값("shopfloor"). current_role 이 없으면 데모 기본값
  (system_admin). 현장(/shopfloor)은 operator/system_admin 만 허용 — 그 외 role 이 직접
  진입하면 role landing(/admin/...)으로 리다이렉트 + 한국어 flash. admin on_mount 의
  `Authorization.allowed?/2` 를 그대로 재사용한다(코드 1줄 공유).
  """
  def on_mount(:assign_shopfloor_context, _params, session, socket) do
    actor = session["actor_id"] || "shopfloor"
    role = session["current_role"] || Authorization.default_role()

    socket =
      socket
      |> assign_new(:current_actor, fn -> actor end)
      |> assign_new(:current_role, fn -> role end)
      |> Phoenix.LiveView.attach_hook(:authorize_shopfloor, :handle_params, &authorize/3)

    {:cont, socket}
  end

  defp authorize(_params, uri, socket) do
    path = URI.parse(uri).path || ""
    role = socket.assigns.current_role

    if Authorization.allowed?(role, path) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         "현장 화면에 접근할 권한이 없습니다. (현재 역할: #{Authorization.role_label(role)})"
       )
       |> Phoenix.LiveView.redirect(to: Authorization.landing(role))}
    end
  end
end
