defmodule OpenMesWeb.CatalogLive do
  @moduledoc """
  확장 카탈로그 홈페이지(설계 §3).

  등록된 확장(EXT-1, EXT-2, 애드온 5개)을 카드로 렌더한다. 카테고리 필터와 활성/비활성
  배지를 제공하며, 자체 화면이 있고 활성인 확장은 "열기" 링크를 노출한다.

  데이터 소스는 `OpenMes.Extensions.Registry.all/0` 하나뿐이다(비활성 포함 전체).
  카탈로그는 도메인 쓰기를 하지 않는다 — 메타데이터 조회 + 렌더뿐(AuditLog/Outbox 무관).
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Extensions.Registry

  # 카테고리 atom → 한국어 라벨. 새 카테고리는 여기에 한 줄 추가.
  @category_labels %{
    ingest: "설비수집",
    media: "멀티미디어",
    production: "생산",
    quality: "품질",
    traceability: "추적",
    analytics: "분석"
  }

  @impl true
  def mount(_params, _session, socket) do
    entries = Registry.all()

    categories =
      entries
      |> Enum.map(& &1.category)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok,
     assign(socket,
       page_title: "확장 카탈로그",
       entries: entries,
       categories: categories,
       filter: :all,
       visible: entries
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
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-8">
        <h1 class="text-2xl font-bold text-zinc-900">확장 카탈로그</h1>
        <p class="mt-1 text-sm text-zinc-500">
          등록된 확장 모듈 {length(@entries)}개. 활성 확장만 화면이 열립니다.
        </p>
      </header>

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
      <div :if={@visible == []} class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
        해당 카테고리에 표시할 확장이 없습니다.
      </div>

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
            <span class={badge_class(entry.enabled)}>
              {if entry.enabled, do: "활성", else: "비활성"}
            </span>
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
    </div>
    """
  end

  # ── 렌더 헬퍼(인라인, pi) ────────────────────────────────────────────

  # 화면이 있고(home_path != nil) 활성인 확장만 "열기" 링크를 노출한다(설계 §3.3).
  defp open_link?(%{home_path: path, enabled: enabled}),
    do: enabled and is_binary(path) and path != ""

  defp category_label(cat), do: Map.get(@category_labels, cat, to_string(cat))

  defp badge_class(true),
    do: "rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700"

  defp badge_class(false),
    do: "rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500"

  defp filter_button_class(true),
    do: "rounded-full bg-indigo-600 px-3 py-1 text-sm font-medium text-white"

  defp filter_button_class(false),
    do:
      "rounded-full border border-zinc-300 px-3 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
end
