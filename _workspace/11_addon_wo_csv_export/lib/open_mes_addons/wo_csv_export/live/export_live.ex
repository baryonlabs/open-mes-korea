defmodule OpenMesWeb.Addons.WoCsvExportLive do
  @moduledoc """
  작업지시 CSV 내보내기 화면(LiveView).

  동작:
    - 상태(status) / 납기일 기간(due_date) 필터를 폼으로 선택한다.
    - 현재 필터 조건에 맞는 작업지시 건수를 실시간 미리보기로 보여준다(읽기 전용 count).
    - "CSV 다운로드" 버튼은 컨트롤러 다운로드 경로로 링크된다.

  왜 컨트롤러로 다운로드를 위임하는가:
    LiveView(WebSocket) 는 파일 첨부 다운로드를 직접 보낼 수 없다. 그래서 필터를 쿼리스트링으로
    실은 일반 HTTP GET(`/extensions/wo-csv-export/download`)으로 이동시키고,
    `WoCsvExportController.download/2` 가 `send_download` 로 CSV 를 내려준다(설계 §2.3 패턴).

  읽기 전용: 이 화면은 도메인 쓰기를 하지 않는다. AuditLog/Outbox 무관.
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.WoCsvExport

  # WorkOrder 상태(영문 → 한국어 라벨). 필터 드롭다운 옵션.
  @status_options [
    {"전체", ""},
    {"초안", "draft"},
    {"확정", "released"},
    {"진행중", "in_progress"},
    {"완료", "completed"},
    {"취소", "cancelled"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    filters = %{"status" => "", "due_date" => ""}

    {:ok,
     socket
     |> assign(page_title: "작업지시 CSV 내보내기")
     |> assign(status_options: @status_options)
     |> assign(filters: filters)
     |> assign_preview(filters)}
  end

  @impl true
  def handle_event("change", %{"filters" => params}, socket) do
    filters = normalize(params)

    {:noreply,
     socket
     |> assign(filters: filters)
     |> assign_preview(filters)}
  end

  # 필터 조건에 맞는 작업지시 건수를 미리보기로 계산한다(읽기 전용).
  defp assign_preview(socket, filters) do
    count = filters |> query_filters() |> OpenMes.Production.list_work_orders() |> length()
    assign(socket, preview_count: count)
  end

  # 화면 폼 값(빈 문자열 포함) → 코어 조회용 필터(빈 값 제거는 퍼사드가 담당하지만,
  # 미리보기 count 를 위해 여기서도 동일 키만 추린다).
  defp query_filters(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp normalize(params) do
    %{
      "status" => Map.get(params, "status", ""),
      "due_date" => Map.get(params, "due_date", "")
    }
  end

  # 현재 필터를 다운로드 URL 쿼리스트링으로 변환(빈 값은 제외).
  defp download_path(filters) do
    query = filters |> query_filters() |> URI.encode_query()
    base = "/extensions/wo-csv-export/download"
    if query == "", do: base, else: base <> "?" <> query
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">작업지시 CSV 내보내기</h1>
        <p class="mt-1 text-sm text-zinc-500">
          상태와 납기일 기준으로 작업지시를 조회해 CSV 파일로 내려받습니다(읽기 전용).
        </p>
      </header>

      <form phx-change="change" class="space-y-5 rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
        <div>
          <label for="filters_status" class="block text-sm font-medium text-zinc-700">상태</label>
          <select
            id="filters_status"
            name="filters[status]"
            class="mt-1 block w-full rounded-md border-zinc-300 text-sm"
          >
            <option :for={{label, value} <- @status_options} value={value} selected={value == @filters["status"]}>
              {label}
            </option>
          </select>
        </div>

        <div>
          <label for="filters_due_date" class="block text-sm font-medium text-zinc-700">납기일</label>
          <input
            type="date"
            id="filters_due_date"
            name="filters[due_date]"
            value={@filters["due_date"]}
            class="mt-1 block w-full rounded-md border-zinc-300 text-sm"
          />
          <p class="mt-1 text-xs text-zinc-400">비워 두면 전체 기간을 내보냅니다.</p>
        </div>

        <div class="flex items-center justify-between border-t border-zinc-100 pt-4">
          <span class="text-sm text-zinc-600">
            현재 조건 작업지시 <strong class="text-zinc-900">{@preview_count}</strong>건
          </span>
          <%!-- 일반 HTTP 링크(다운로드는 컨트롤러가 처리). LiveView 는 파일 첨부를 직접 못 보냄. --%>
          <a
            href={download_path(@filters)}
            class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-500"
          >
            CSV 다운로드
          </a>
        </div>
      </form>

      <div class="mt-4">
        <.link navigate="/extensions" class="text-sm text-zinc-500 hover:text-zinc-700">← 확장 카탈로그로</.link>
      </div>
    </div>
    """
  end
end
