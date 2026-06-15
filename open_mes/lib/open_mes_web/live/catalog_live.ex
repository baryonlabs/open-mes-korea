defmodule OpenMesWeb.CatalogLive do
  @moduledoc """
  확장 카탈로그 홈페이지(설계 §3).

  등록된 확장(EXT-1, EXT-2, 애드온 5개)을 카드로 렌더한다. 카테고리 필터와 활성/비활성
  배지를 제공하며, 자체 화면이 있고 활성인 확장은 "열기" 링크를 노출한다.

  데이터 소스는 `OpenMes.Extension.Registry.all/0` 하나뿐이다(비활성 포함 전체).
  카탈로그는 도메인 쓰기를 하지 않는다 — 메타데이터 조회 + 렌더뿐(AuditLog/Outbox 무관).

  레이아웃: 다른 관리자 화면(/admin/*)과 동일하게 `OpenMesWeb.Admin.AdminLive` 베이스를
  use 하여 공통 admin 레이아웃(사이드바·상단바·role 배지)과 `admin_shell`/`page_header`/
  카드 스타일을 공유한다. /extensions 는 인가상 system_admin 영역(Authorization)이므로
  on_mount 가 current_role/current_path 를 주입한다(라우트 /extensions 유지).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Extension.Registry

  # SDK 섹션의 "최소 확장" 코드 미리보기. 모듈 속성에 두어 HEEx 안 heredoc 들여쓰기 충돌을 피한다(pi).
  @sample_extension """
  defmodule MyExt.Extension do
    use OpenMes.Extension.Definition

    def id, do: :addon_my_ext
    def name, do: "우리 회사 확장"
    def description, do: "현장 맞춤 기능(읽기 전용)."
    def category, do: :analytics
    def version, do: "0.1.0"
    def enabled?, do: true
  end
  """

  # known 카테고리 atom → 한국어 라벨. 미지 카테고리는 atom 폴백 라벨(아래 category_label/1).
  # 새 코어 카테고리는 여기 + Extension.known_categories/0 에 추가.
  @category_labels %{
    ingest: "설비수집",
    media: "멀티미디어",
    production: "생산",
    quality: "품질",
    traceability: "추적",
    analytics: "분석",
    integration: "연동"
  }

  @impl true
  def mount(_params, _session, socket) do
    entries = Registry.all()

    # 동적 카테고리 칩: 등장한 카테고리의 합집합. known 우선 정렬, 미지는 뒤에(설계 30 §4).
    # 외부 확장이 자유 카테고리를 써도 칩이 자동 생성된다(하드코딩 제거).
    known = OpenMes.Extension.known_categories()

    categories =
      entries
      |> Enum.map(& &1.category)
      |> Enum.uniq()
      |> Enum.sort_by(fn cat ->
        case Enum.find_index(known, &(&1 == cat)) do
          nil -> {1, to_string(cat)}
          idx -> {0, idx}
        end
      end)

    {:ok,
     assign(socket,
       page_title: "확장 카탈로그",
       entries: entries,
       categories: categories,
       filter: :all,
       visible: entries,
       sample_extension: @sample_extension
     )}
  end

  @impl true
  def handle_event("filter", %{"category" => "all"}, socket) do
    {:noreply, assign(socket, filter: :all, visible: socket.assigns.entries)}
  end

  def handle_event("filter", %{"category" => cat}, socket) do
    # String.to_existing_atom: 미리 정의된 카테고리 atom 만 허용(임의 atom 생성 방지).
    cat_atom = String.to_existing_atom(cat)
    visible = Enum.filter(socket.assigns.entries, &(&1.category == cat_atom))
    {:noreply, assign(socket, filter: cat_atom, visible: visible)}
  end

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
        title="확장 카탈로그"
        subtitle={"등록된 확장 모듈 #{length(@entries)}개. 활성 확장만 화면이 열립니다."}
        roles={["system_admin"]}
      />

      <%!-- 카테고리 필터 --%>
      <nav class="mb-6 flex flex-wrap gap-2" aria-label="카테고리 필터">
        <button
          type="button"
          phx-click="filter"
          phx-value-category="all"
          class={filter_button_class(@filter == :all)}
        >
          전체
        </button>
        <button
          :for={cat <- @categories}
          type="button"
          phx-click="filter"
          phx-value-category={cat}
          class={filter_button_class(@filter == cat)}
        >
          {category_label(cat)}
        </button>
      </nav>

      <%!-- 카드 그리드 --%>
      <.empty_state :if={@visible == []} message="해당 카테고리에 표시할 확장이 없습니다." />

      <ul :if={@visible != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <li
          :for={entry <- @visible}
          id={"extension-#{entry.id}"}
          class="flex flex-col rounded-lg border border-zinc-200 bg-white p-5 shadow-sm"
        >
          <div class="mb-2 flex items-start justify-between gap-2">
            <span class="rounded bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-600">
              {category_label(entry.category)}
            </span>
            <.active_badge active={entry.enabled} />
          </div>

          <h2 class="text-base font-semibold text-zinc-900">{entry.name}</h2>
          <p class="mt-1 flex-1 text-sm text-zinc-600">{entry.description}</p>

          <div class="mt-4 flex items-center justify-between">
            <span class="text-xs text-zinc-400">v{entry.version}</span>
            <.link
              :if={open_link?(entry)}
              navigate={entry.home_path}
              class="text-sm font-medium text-indigo-600 hover:text-indigo-500"
            >
              열기 →
            </.link>
          </div>
        </li>
      </ul>

      <%!-- 나만의 확장 만들기 (SDK 안내) ─────────────────────────────── --%>
      <section class="mt-10 rounded-lg border border-indigo-200 bg-indigo-50/60 p-6 shadow-sm">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="max-w-2xl">
            <h2 class="text-lg font-semibold text-zinc-900">
              회사에 맞는 확장을 직접 만들 수 있습니다
            </h2>
            <p class="mt-2 text-sm text-zinc-600">
              현장 요구(특정 설비·리포트·라벨·외부 도구 연동)는 코어를 건드리지 않고 확장 모듈로 직접 구현합니다.
              <span class="font-medium text-zinc-800">코어 비침투</span> · <span class="font-medium text-zinc-800">config on/off</span> ·
              <span class="font-medium text-zinc-800">카탈로그 자동 노출</span> —
              <code class="rounded bg-white px-1 text-xs">Extension</code> behaviour만 구현하면 이 카탈로그에 카드가 자동으로 뜹니다.
            </p>
            <div class="mt-4 flex flex-wrap gap-3">
              <.link
                navigate={~p"/extensions/guide"}
                class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500"
              >
                확장 개발 가이드 →
              </.link>
              <.link
                navigate={~p"/extensions/guide"}
                class="rounded-md border border-indigo-300 bg-white px-4 py-2 text-sm font-medium text-indigo-700 hover:bg-indigo-50"
              >
                Extension SDK 레퍼런스
              </.link>
            </div>
          </div>

          <%!-- 최소 확장 코드 미리보기(인라인 스니펫) --%>
          <pre class="overflow-x-auto rounded-md bg-zinc-900 p-4 text-[11px] leading-relaxed text-zinc-100 lg:max-w-md"><code>{@sample_extension}</code></pre>
        </div>
      </section>
    </.admin_shell>
    """
  end

  # ── 렌더 헬퍼(인라인, pi) ────────────────────────────────────────────

  # 화면이 있고(home_path != nil) 활성인 확장만 "열기" 링크를 노출한다(설계 §3.3).
  defp open_link?(%{home_path: path, enabled: enabled}),
    do: enabled and is_binary(path) and path != ""

  # known 이면 한국어 라벨, 미지면 atom 폴백(`:my_cat` → "my cat").
  defp category_label(cat) do
    Map.get_lazy(@category_labels, cat, fn ->
      cat |> to_string() |> String.replace("_", " ")
    end)
  end

  defp filter_button_class(true),
    do: "rounded-full bg-indigo-600 px-3 py-1 text-sm font-medium text-white"

  defp filter_button_class(false),
    do:
      "rounded-full border border-zinc-300 px-3 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
end
