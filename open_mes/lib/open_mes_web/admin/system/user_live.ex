defmodule OpenMesWeb.Admin.System.UserLive do
  @moduledoc """
  G6 관리자 — 사용자/권한(MVP 간이).

  MVP 범위(설계 §2.5): 본격 RBAC 는 후순위. 여기서는 Worker 목록을 "사용자"로 보여주고
  역할(role)을 표시만 한다(영역 구분 수준). 과한 auth/권한 매트릭스 도입 금지.

  읽기 전용 조회(Worker 목록은 `OpenMes.MasterData.list_workers/1` 경유).
  현재 세션 actor 도 함께 표시한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "사용자/권한")
     |> assign(workers: MasterData.list_workers(%{"limit" => "200"}))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header
        title="사용자/권한"
        subtitle="작업자를 사용자로 표시(역할 색상 — 본격 RBAC 는 후속)"
        roles={OpenMesWeb.Authorization.roles_for_path(@current_path)}
      />

      <div class="mb-6 rounded-lg border border-indigo-100 bg-indigo-50 p-4 text-sm text-indigo-800">
        현재 세션 작업자(actor): <span class="font-semibold">{@current_actor || "미지정"}</span>
        <p class="mt-1 text-xs text-indigo-600">
          MVP 에서는 영역(관리자/현장) 구분만 적용합니다. 세밀한 권한 관리는 후속 단계입니다.
        </p>
      </div>

      <.empty_state :if={@workers == []} message="등록된 작업자가 없습니다. 기준정보 > 작업자에서 등록하세요." />

      <.table :if={@workers != []} id="users" rows={@workers}>
        <:col :let={w} label="사용자 코드">{w.worker_code}</:col>
        <:col :let={w} label="이름">{w.name}</:col>
        <:col :let={w} label="역할"><.role_badge role={w.role} /></:col>
        <:col :let={w} label="상태"><.active_badge active={w.active} /></:col>
        <:action :let={w}>
          <.link navigate={~p"/admin/workers/#{w.id}/edit"} class="text-indigo-600 hover:underline">
            작업자 수정
          </.link>
        </:action>
      </.table>
    </.admin_shell>
    """
  end
end
