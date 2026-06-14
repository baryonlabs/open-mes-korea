defmodule OpenMesWeb.Admin.AdminLive do
  @moduledoc """
  관리자(/admin) LiveView 공통 베이스.

  `use OpenMesWeb.Admin.AdminLive` 한 줄로:
    - `:admin` 레이아웃 적용
    - core_components / admin_components import
    - 현재 actor / 현재 경로 추적용 `on_mount` 훅 부착

  설계 §2.4(공통 레이아웃), §2.5(세션 간이 actor — MVP). 인증 RBAC 는 후속(과설계 금지).
  """
  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView, layout: {OpenMesWeb.Layouts, :admin}

      on_mount {OpenMesWeb.Admin.AdminLive, :assign_admin_context}

      import Phoenix.HTML
      import OpenMesWeb.CoreComponents
      import OpenMesWeb.AdminComponents
      import OpenMesWeb.Gettext

      alias Phoenix.LiveView.JS

      use Phoenix.VerifiedRoutes,
        endpoint: OpenMesWeb.Endpoint,
        router: OpenMesWeb.Router,
        statics: OpenMesWeb.static_paths()
    end
  end

  import Phoenix.LiveView
  import Phoenix.Component

  alias OpenMesWeb.Authorization

  @doc """
  on_mount 훅: 세션 actor(MVP 간이) + role 주입 + URI 기반 경로 추적 + 인가(설계 §3.2).

  세션에 actor_id 가 없으면 MVP 기본값("admin"). current_role 이 없으면 데모 기본값
  (system_admin — 전체 보임). handle_params 마다 경로를 갱신하고 `allowed?` 인가를
  검사한다. 거부 시 role landing 으로 리다이렉트 + 한국어 flash(직접 URL/navigate 차단).
  """
  def on_mount(:assign_admin_context, _params, session, socket) do
    actor = session["actor_id"] || "admin"
    role = session["current_role"] || Authorization.default_role()

    socket =
      socket
      |> assign_new(:current_actor, fn -> actor end)
      |> assign_new(:current_role, fn -> role end)
      |> assign_new(:current_path, fn -> "" end)
      |> attach_hook(:track_admin_path, :handle_params, &track_path_and_authorize/3)

    {:cont, socket}
  end

  # handle_params 마다 현재 경로 갱신 + 인가. 거부 시 redirect(halt).
  defp track_path_and_authorize(_params, uri, socket) do
    path = URI.parse(uri).path || ""
    socket = assign(socket, :current_path, path)
    role = socket.assigns.current_role

    if Authorization.allowed?(role, path) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         "이 화면에 접근할 권한이 없습니다. (현재 역할: #{Authorization.role_label(role)})"
       )
       |> Phoenix.LiveView.redirect(to: Authorization.landing(role))}
    end
  end
end
