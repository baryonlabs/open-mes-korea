defmodule OpenMesWeb.ShopfloorComponents do
  @moduledoc """
  현장(/shopfloor) 영역 공통 컴포넌트 — 태블릿 대형 터치 UX (설계 §2.1, §2.3, §2.4).

  ## pi 준수

    - 외부 JS/차트 0. Tailwind CSS + 서버 렌더뿐.
    - admin 사이드바와 다른 단순 단일 컬럼 레이아웃(현장 작업자 대상).
    - 큰 버튼/큰 글씨/최소 입력. 상태 색상은 AdminComponents 와 동일 의미 체계.
  """
  use Phoenix.Component

  import OpenMesWeb.CoreComponents, only: [icon: 1]
  # role 배지는 admin 컴포넌트를 재사용한다(중복 정의 금지 — pi §0-5).
  import OpenMesWeb.AdminComponents, only: [role_badge: 1]

  @doc """
  현장 페이지 골격(상단바 + 단일 컬럼 본문). 사이드바 없음(현장 단순 UX).
  뒤로가기 링크(back)를 옵션으로 노출한다.

  상단바에 역할 전환 드롭다운을 둔다 — 현장은 사이드바가 없어 admin 상단바의
  역할 전환 UI가 닿지 않으므로, operator 등 비-admin role 로 전환했을 때 다시
  되돌릴 경로(lockout 방지)가 반드시 여기 있어야 한다. admin_topbar 의 `<details>`
  마크업과 동일한 `POST /session/role/:role` 링크를 이식한다.
  """
  attr :title, :string, required: true
  attr :current_actor, :string, default: nil
  attr :current_role, :string, default: nil
  attr :back, :string, default: nil
  slot :inner_block, required: true

  def shopfloor_shell(assigns) do
    role = assigns.current_role || OpenMesWeb.Authorization.default_role()

    assigns =
      assigns
      |> assign(:current_role, role)
      |> assign(:roles, OpenMesWeb.Authorization.roles())

    ~H"""
    <div class="min-h-screen bg-zinc-100">
      <header class="flex h-16 items-center justify-between bg-zinc-900 px-5 text-white">
        <div class="flex items-center gap-3">
          <.link
            :if={@back}
            navigate={@back}
            class="flex h-11 w-11 items-center justify-center rounded-lg bg-zinc-700 text-white hover:bg-zinc-600"
            aria-label="뒤로"
          >
            <.icon name="hero-arrow-left" class="h-6 w-6" />
          </.link>
          <div class="flex flex-col leading-tight">
            <span class="text-[11px] font-medium text-zinc-400">Open MES Korea</span>
            <span class="text-lg font-bold">{@title}</span>
          </div>
        </div>
        <div class="flex items-center gap-4 text-sm">
          <span class="text-zinc-300">
            작업자 <span class="font-semibold text-white">{@current_actor || "미지정"}</span>
          </span>
          <details class="relative">
            <summary class="flex cursor-pointer list-none items-center gap-1 rounded text-zinc-300 hover:text-white">
              <span class="text-xs text-zinc-400">역할</span>
              <.role_badge role={@current_role} />
              <.icon name="hero-chevron-down" class="h-3.5 w-3.5 text-zinc-400" />
            </summary>
            <div class="absolute right-0 z-20 mt-2 w-52 rounded-lg border border-zinc-200 bg-white p-2 text-zinc-800 shadow-lg">
              <p class="px-2 pb-1 text-[11px] text-zinc-400">역할 전환(데모)</p>
              <.link
                :for={r <- @roles}
                href={"/session/role/#{r.key}"}
                method="post"
                class={[
                  "flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-zinc-100",
                  r.key == @current_role && "font-semibold"
                ]}
              >
                <span class={["h-2 w-2 rounded-full", r.dot_class]}></span>
                <span>{r.label}</span>
                <span :if={r.key == @current_role} class="ml-auto text-xs text-zinc-400">현재</span>
              </.link>
            </div>
          </details>
          <.link navigate="/admin/items" class="text-zinc-300 hover:text-white">관리자</.link>
        </div>
      </header>
      <main class="mx-auto max-w-3xl px-4 py-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc """
  대형 액션 버튼(현장 터치). color 로 의미 구분(start=green, complete=indigo, pause=amber, skip=zinc, danger=red).
  phx-click 등 임의 속성은 rest 로 전달한다.
  """
  attr :color, :string, default: "zinc"
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-to phx-disable-with disabled type data-confirm name value)
  slot :inner_block, required: true

  def big_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "min-h-16 w-full rounded-2xl px-6 py-4 text-xl font-bold shadow-sm transition active:scale-[0.98] disabled:opacity-40",
        big_button_color(@color),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp big_button_color("start"), do: "bg-green-600 text-white hover:bg-green-500"
  defp big_button_color("complete"), do: "bg-indigo-600 text-white hover:bg-indigo-500"
  defp big_button_color("pause"), do: "bg-amber-500 text-white hover:bg-amber-400"
  defp big_button_color("danger"), do: "bg-red-600 text-white hover:bg-red-500"
  defp big_button_color("primary"), do: "bg-zinc-900 text-white hover:bg-zinc-700"
  defp big_button_color(_), do: "bg-white text-zinc-800 ring-1 ring-inset ring-zinc-300 hover:bg-zinc-50"

  @doc "현장용 큰 상태 배지(공정 상태 머신 공용)."
  attr :status, :string, required: true

  def big_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-3 py-1 text-base font-semibold",
      sf_status_class(@status)
    ]}>
      {sf_status_text(@status)}
    </span>
    """
  end

  defp sf_status_class(s) when s in ["pending"], do: "bg-zinc-200 text-zinc-700"
  defp sf_status_class(s) when s in ["ready"], do: "bg-blue-100 text-blue-700"
  defp sf_status_class(s) when s in ["running"], do: "bg-indigo-100 text-indigo-700"
  defp sf_status_class("paused"), do: "bg-amber-100 text-amber-700"
  defp sf_status_class("completed"), do: "bg-green-100 text-green-700"
  defp sf_status_class("skipped"), do: "bg-zinc-200 text-zinc-500"
  defp sf_status_class(_), do: "bg-zinc-200 text-zinc-600"

  defp sf_status_text("pending"), do: "대기"
  defp sf_status_text("ready"), do: "준비"
  defp sf_status_text("running"), do: "진행중"
  defp sf_status_text("paused"), do: "일시정지"
  defp sf_status_text("completed"), do: "완료"
  defp sf_status_text("skipped"), do: "건너뜀"
  defp sf_status_text(other), do: other

  @doc "현장 빈 상태 안내(큰 글씨)."
  attr :message, :string, required: true

  def sf_empty(assigns) do
    ~H"""
    <div class="rounded-2xl border-2 border-dashed border-zinc-300 bg-white p-10 text-center text-lg text-zinc-500">
      {@message}
    </div>
    """
  end
end
