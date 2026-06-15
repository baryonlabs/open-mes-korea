defmodule OpenMesWeb.AdminComponents do
  @moduledoc """
  관리자(/admin) 영역 공통 컴포넌트 — 사이드바 네비게이션 + 페이지 헤더.

  설계 §2.2(관리자 메뉴 트리), §2.4(공통 레이아웃 모듈) 구현.

  ## pi 준수

    - 외부 JS/차트 라이브러리 도입 0. CSS(Tailwind) + 서버 렌더뿐.
    - 메뉴 트리는 모듈 속성(`@menu`) 한 곳에서 관리한다. 새 메뉴는 여기 한 줄 추가.
    - 현재 활성 메뉴는 `current_path`(LiveView 의 `@current_path`)와 항목 path 의
      접두어 비교로 판정한다(별도 라우터 introspection 불필요).
    - 생산관리/조회·대시보드/관리자 그룹은 아직 화면이 없으므로(G2~G6 담당) 자리만
      잡고 비활성(`disabled`) 표시한다. 확장 카탈로그(/extensions)는 외부 링크.
  """
  use Phoenix.Component

  import OpenMesWeb.CoreComponents, only: [icon: 1]

  # 메뉴 트리(설계 §2.2). 각 항목은 %{label, path, enabled, roles}.
  # roles: system_admin 외에 그 화면을 추가로 볼 수 있는 role(영문). system_admin 은
  #   Authorization 에서 항상 포함되므로 여기 명시하지 않는다(설계 §2.1).
  # enabled?=false 인 항목은 아직 구현 전(자리만) — 흐리게 표시하고 링크하지 않는다.
  # role 매핑·인가·배지·가시성이 모두 이 한 트리를 본다(중복 정의 금지, 설계 §0-5).
  @menu [
    %{
      group: "기준정보",
      items: [
        %{label: "품목", path: "/admin/items", enabled: true, roles: ["production_manager"]},
        %{label: "BOM", path: "/admin/boms", enabled: true, roles: ["production_manager"]},
        %{label: "공정", path: "/admin/processes", enabled: true, roles: ["production_manager"]},
        %{label: "라우팅", path: "/admin/routings", enabled: true, roles: ["production_manager"]},
        %{label: "설비", path: "/admin/equipment", enabled: true, roles: ["production_manager"]},
        %{label: "작업자", path: "/admin/workers", enabled: true, roles: ["production_manager"]}
      ]
    },
    %{
      group: "생산관리",
      items: [
        %{label: "작업지시", path: "/admin/work-orders", enabled: true, roles: ["production_manager"]}
      ]
    },
    %{
      group: "LOT 추적",
      items: [
        %{
          label: "자재 LOT",
          path: "/admin/lots",
          enabled: true,
          roles: ["material_manager", "quality_manager"]
        }
      ]
    },
    %{
      group: "조회/대시보드",
      items: [
        %{
          label: "생산 현황",
          path: "/admin/dashboard",
          enabled: true,
          roles: ["production_manager", "quality_manager"]
        },
        %{
          label: "공정별 실적",
          path: "/admin/reports/production",
          enabled: true,
          roles: ["production_manager", "quality_manager"]
        },
        %{
          label: "불량 현황",
          path: "/admin/reports/defects",
          enabled: true,
          roles: ["production_manager", "quality_manager"]
        },
        %{
          label: "LOT 이력",
          path: "/admin/reports/lots",
          enabled: true,
          roles: ["quality_manager", "material_manager"]
        },
        %{
          label: "재고 흐름",
          path: "/admin/reports/inventory",
          enabled: true,
          roles: ["material_manager", "production_manager"]
        }
      ]
    },
    %{
      group: "설정",
      items: [
        # 생산라인 구성(라인 모니터 표시 구성 — 설계 22번). system_admin 은 Authorization 항상 포함.
        %{
          label: "생산라인 구성",
          path: "/admin/settings/lines",
          enabled: true,
          roles: ["production_manager"]
        },
        # AI 자연어 라인 구성(propose→승인→실행, 설계 23번) — 실동작.
        %{
          label: "AI 라인 구성",
          path: "/admin/settings/ai-line",
          enabled: true,
          roles: ["production_manager"]
        },
        # 지식베이스(OKF RAG 문서, 설계 27번) — 품질관리자 주관리(system_admin 항상).
        %{
          label: "지식베이스",
          path: "/admin/settings/knowledge",
          enabled: true,
          roles: ["quality_manager"]
        },
        # Skill/MCP/Connector 는 시스템 구성이라 system_admin 전용(roles: []).
        %{label: "Skill 설정", path: "/admin/settings/skills", enabled: true, roles: []},
        %{label: "MCP 설정", path: "/admin/settings/mcp", enabled: true, roles: []},
        %{label: "Connector 설정", path: "/admin/settings/connectors", enabled: true, roles: []}
      ]
    },
    %{
      group: "AI",
      items: [
        # AI 종합 조사(시계열+미디어+생산, Level 1 Read-only, 설계 25번). 품질관리자 포함.
        %{
          label: "AI 조사",
          path: "/admin/ai/investigate",
          enabled: true,
          roles: ["production_manager", "quality_manager"]
        }
      ]
    },
    %{
      group: "관리자",
      items: [
        # system_admin 전용(추가 role 없음).
        %{label: "사용자/권한", path: "/admin/users", enabled: true, roles: []},
        %{label: "감사 로그", path: "/admin/audit-logs", enabled: true, roles: []}
      ]
    }
  ]

  @doc "관리자 메뉴 트리(외부에서 참조용)."
  def menu, do: @menu

  @doc """
  관리자 사이드바. 현재 경로(`current_path`)에 해당하는 메뉴를 강조한다.
  `current_role` 로 보이는 메뉴를 필터한다(비-admin 은 허용 화면만, 설계 §3.1).
  system_admin 일 때만 각 항목 옆에 그 화면의 role 색 점을 표시한다(설계 §4.3).
  """
  attr :current_path, :string, default: ""
  attr :current_role, :string, default: nil

  def admin_sidebar(assigns) do
    role = assigns.current_role || OpenMesWeb.Authorization.default_role()

    assigns =
      assigns
      |> assign(:menu, OpenMesWeb.Authorization.visible_menu(role))
      |> assign(:current_role, role)
      |> assign(:admin?, role == "system_admin")

    ~H"""
    <aside class="hidden w-60 shrink-0 border-r border-zinc-200 bg-zinc-50 lg:block">
      <div class="flex h-14 items-center border-b border-zinc-200 px-5">
        <.link navigate="/admin/items" class="text-base font-bold text-zinc-900">
          Open MES Korea
        </.link>
      </div>
      <nav class="px-3 py-4" aria-label="관리자 메뉴">
        <div :for={group <- @menu} class="mb-5">
          <p class="px-2 pb-1 text-xs font-semibold uppercase tracking-wide text-zinc-400">
            {group.group}
          </p>
          <ul class="space-y-0.5">
            <li :for={item <- group.items}>
              <.link
                :if={item.enabled}
                navigate={item.path}
                class={menu_item_class(active?(@current_path, item.path))}
                aria-current={if active?(@current_path, item.path), do: "page"}
              >
                <span class="flex items-center justify-between gap-1">
                  <span>{item.label}</span>
                  <.role_dots :if={@admin?} roles={OpenMesWeb.Authorization.roles_for_path(item.path)} />
                </span>
              </.link>
              <span :if={!item.enabled} class={menu_disabled_class()} title="준비 중">
                {item.label}
                <span class="ml-1 text-[10px] text-zinc-400">준비중</span>
              </span>
            </li>
          </ul>
        </div>

        <div class="mt-6 border-t border-zinc-200 pt-4">
          <.link navigate="/extensions" class={menu_item_class(false)}>
            확장 카탈로그 →
          </.link>
        </div>
      </nav>
    </aside>
    """
  end

  @doc """
  관리자 상단바(모바일/공통). 로고 + 현재 actor + 홈/확장 링크.
  모바일에서는 사이드바가 숨겨지므로 메뉴 토글을 노출한다(간이 — details/summary).
  """
  attr :current_actor, :string, default: nil
  attr :current_path, :string, default: ""
  attr :current_role, :string, default: nil

  def admin_topbar(assigns) do
    role = assigns.current_role || OpenMesWeb.Authorization.default_role()

    assigns =
      assigns
      |> assign(:menu, OpenMesWeb.Authorization.visible_menu(role))
      |> assign(:current_role, role)
      |> assign(:roles, OpenMesWeb.Authorization.roles())

    ~H"""
    <header class="flex h-14 items-center justify-between border-b border-zinc-200 bg-white px-4 sm:px-6">
      <div class="flex items-center gap-3">
        <details class="relative lg:hidden">
          <summary class="cursor-pointer list-none rounded p-1.5 text-zinc-600 hover:bg-zinc-100">
            <.icon name="hero-bars-3" class="h-5 w-5" />
          </summary>
          <div class="absolute left-0 z-20 mt-2 w-56 rounded-lg border border-zinc-200 bg-white p-3 shadow-lg">
            <div :for={group <- @menu} class="mb-3">
              <p class="pb-1 text-xs font-semibold uppercase text-zinc-400">{group.group}</p>
              <ul>
                <li :for={item <- group.items}>
                  <.link
                    :if={item.enabled}
                    navigate={item.path}
                    class={menu_item_class(active?(@current_path, item.path))}
                  >
                    {item.label}
                  </.link>
                  <span :if={!item.enabled} class={menu_disabled_class()}>{item.label}</span>
                </li>
              </ul>
            </div>
          </div>
        </details>
        <span class="text-sm font-semibold text-zinc-900 lg:hidden">Open MES Korea</span>
      </div>

      <div class="flex items-center gap-4 text-sm">
        <span class="text-zinc-500">
          작업자: <span class="font-medium text-zinc-800">{@current_actor || "미지정"}</span>
        </span>
        <details class="relative">
          <summary class="flex cursor-pointer list-none items-center gap-1 rounded hover:opacity-80">
            <span class="text-xs text-zinc-400">역할</span>
            <.role_badge role={@current_role} />
            <.icon name="hero-chevron-down" class="h-3.5 w-3.5 text-zinc-400" />
          </summary>
          <div class="absolute right-0 z-20 mt-2 w-52 rounded-lg border border-zinc-200 bg-white p-2 shadow-lg">
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
        <.link navigate="/shopfloor" class="text-indigo-600 hover:text-indigo-800">현장 모드 →</.link>
        <.link navigate="/" class="text-zinc-500 hover:text-zinc-800">홈</.link>
      </div>
    </header>
    """
  end

  @doc """
  /admin 페이지 공통 골격(사이드바 + 상단바 + 본문). LiveView render 안에서 감싼다.
  """
  attr :current_path, :string, default: ""
  attr :current_actor, :string, default: nil
  attr :current_role, :string, default: nil
  attr :flash, :map, default: %{}
  slot :inner_block, required: true

  def admin_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-white">
      <.admin_sidebar current_path={@current_path} current_role={@current_role} />
      <div class="flex min-w-0 flex-1 flex-col">
        <.admin_topbar
          current_actor={@current_actor}
          current_path={@current_path}
          current_role={@current_role}
        />
        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  페이지 헤더(제목 + 설명 + 우측 액션 슬롯).
  `roles` 를 주면 이 화면의 허용 role 배지 묶음을 제목 옆에 표시한다(설계 §4.3).
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :roles, :list, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="mb-6 flex flex-wrap items-end justify-between gap-3 border-b border-zinc-100 pb-4">
      <div>
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-xl font-bold text-zinc-900">{@title}</h1>
          <.role_badges :if={@roles} roles={@roles} />
        </div>
        <p :if={@subtitle} class="mt-1 text-sm text-zinc-500">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  역할(role) 색상 배지. role key 를 받아 한국어명 + 색으로 표시한다(설계 §4.2).
  미지정/미지 role 은 zinc fallback.
  """
  attr :role, :string, required: true
  attr :size, :string, default: "sm"

  def role_badge(assigns) do
    meta = OpenMesWeb.Authorization.role(assigns.role)
    assigns = assign(assigns, :meta, meta)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full font-medium",
      @size == "xs" && "px-1.5 py-0.5 text-[11px]",
      @size != "xs" && "px-2 py-0.5 text-xs",
      @meta.badge_class
    ]}>
      <span class={["h-1.5 w-1.5 rounded-full", @meta.dot_class]}></span>
      {@meta.label}
    </span>
    """
  end

  @doc "여러 role 배지를 한 줄에 나열(화면 헤더용)."
  attr :roles, :list, required: true

  def role_badges(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-center gap-1">
      <.role_badge :for={r <- @roles} role={r} size="xs" />
    </span>
    """
  end

  @doc "여러 role 의 색 점만 나열(사이드바 항목용 — 노이즈 최소)."
  attr :roles, :list, required: true

  def role_dots(assigns) do
    assigns = assign(assigns, :dots, Enum.map(assigns.roles, &OpenMesWeb.Authorization.role_dot_class/1))

    ~H"""
    <span class="inline-flex items-center gap-0.5" aria-hidden="true">
      <span :for={dot <- @dots} class={["h-1.5 w-1.5 rounded-full", dot]}></span>
    </span>
    """
  end

  @doc "활성/비활성 상태 배지."
  attr :active, :boolean, required: true

  def active_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded-full px-2 py-0.5 text-xs font-medium",
      @active && "bg-green-100 text-green-700",
      !@active && "bg-zinc-100 text-zinc-500"
    ]}>
      {if @active, do: "활성", else: "비활성"}
    </span>
    """
  end

  @doc """
  상태 배지(작업지시/공정 상태 머신 공용). status 문자열을 의미별 색상으로 표시한다.

  생산관리(G2) 상태값:
    - 작업지시: draft / released / in_progress / completed / cancelled
    - 공정:    pending / ready / running / paused / completed / skipped
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded-full px-2 py-0.5 text-xs font-medium",
      status_badge_class(@status)
    ]}>
      {status_text(@status)}
    </span>
    """
  end

  # 진행 흐름 색상: 초기=zinc, 지시/준비=blue, 진행중=indigo, 완료=green, 취소/건너뜀=red/zinc.
  defp status_badge_class(s) when s in ["draft", "pending"], do: "bg-zinc-100 text-zinc-600"
  defp status_badge_class(s) when s in ["released", "ready"], do: "bg-blue-100 text-blue-700"
  defp status_badge_class(s) when s in ["in_progress", "running"], do: "bg-indigo-100 text-indigo-700"
  defp status_badge_class("paused"), do: "bg-amber-100 text-amber-700"
  defp status_badge_class("completed"), do: "bg-green-100 text-green-700"
  defp status_badge_class("cancelled"), do: "bg-red-100 text-red-700"
  defp status_badge_class("skipped"), do: "bg-zinc-100 text-zinc-500"
  defp status_badge_class(_), do: "bg-zinc-100 text-zinc-600"

  defp status_text("draft"), do: "작성중"
  defp status_text("released"), do: "지시"
  defp status_text("in_progress"), do: "진행중"
  defp status_text("completed"), do: "완료"
  defp status_text("cancelled"), do: "취소"
  defp status_text("pending"), do: "대기"
  defp status_text("ready"), do: "준비"
  defp status_text("running"), do: "진행"
  defp status_text("paused"), do: "일시정지"
  defp status_text("skipped"), do: "건너뜀"
  defp status_text(other), do: other

  @doc "빈 상태 안내(의존 데이터 없음 등)."
  attr :message, :string, required: true
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
      {@message}
      <div :if={@inner_block != []} class="mt-3">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  # ── 헬퍼 ────────────────────────────────────────────────────────────

  # 현재 경로가 메뉴 path 로 시작하면 활성(예: /admin/items/new 도 품목 활성).
  defp active?(current, path) when is_binary(current),
    do: current == path or String.starts_with?(current, path <> "/")

  defp active?(_current, _path), do: false

  defp menu_item_class(true),
    do: "block rounded-md bg-indigo-600 px-2 py-1.5 text-sm font-medium text-white"

  defp menu_item_class(false),
    do:
      "block rounded-md px-2 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-200 hover:text-zinc-900"

  defp menu_disabled_class,
    do: "block cursor-not-allowed rounded-md px-2 py-1.5 text-sm font-medium text-zinc-400"
end
