defmodule OpenMesWeb.Admin.Reports.LotHistoryLive do
  @moduledoc """
  G5 조회/대시보드 — LOT 이력 조회.

  MaterialLot 목록/검색(lot_no) + 상태 필터를 제공하고, 각 LOT 의 계보(genealogy)
  화면(G3, `/admin/lots/:id/genealogy`)으로 링크한다. 읽기 전용(도메인 쓰기 0).

  목록은 `OpenMes.Lots.list_lots/1` 경유. 검색은 서버 메모리 부분일치(pi, 페이지 크기 내).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Lots
  alias OpenMes.MasterData

  @statuses ~w(available reserved produced consumed quarantined scrapped)

  defp statuses, do: @statuses

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "LOT 이력 조회", query: "", status_filter: "all")
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"query" => query, "status" => status}, socket) do
    {:noreply, socket |> assign(query: query, status_filter: status) |> load()}
  end

  defp load(socket) do
    lots =
      Lots.list_lots(filters(socket))
      |> filter_query(socket.assigns.query)

    items = MasterData.items_map(Enum.map(lots, & &1.item_id))
    assign(socket, lots: lots, items: items)
  end

  defp filters(%{assigns: %{status_filter: s}}) when s in @statuses, do: %{"status" => s}
  defp filters(_socket), do: %{}

  defp filter_query(lots, ""), do: lots

  defp filter_query(lots, query) do
    q = String.downcase(query)
    Enum.filter(lots, fn lot -> String.contains?(String.downcase(lot.lot_no), q) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="LOT 이력 조회" subtitle="자재/제품 LOT 목록·상태 + 계보(genealogy) 추적" />

      <form phx-change="search" phx-submit="search" class="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-500">LOT 번호</label>
          <input type="text" name="query" value={@query} placeholder="LOT 번호"
            phx-debounce="300" class="mt-1 rounded-lg border-zinc-300 text-sm" />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">상태</label>
          <select name="status" class="mt-1 rounded-lg border-zinc-300 text-sm">
            <option value="all" selected={@status_filter == "all"}>전체</option>
            <option :for={s <- statuses()} value={s} selected={@status_filter == s}>{lot_status_label(s)}</option>
          </select>
        </div>
      </form>

      <.empty_state :if={@lots == []} message="조회된 LOT 가 없습니다." />

      <.table :if={@lots != []} id="lot-history" rows={@lots}>
        <:col :let={lot} label="LOT 번호"><span class="font-mono">{lot.lot_no}</span></:col>
        <:col :let={lot} label="품목">{item_label(@items, lot.item_id)}</:col>
        <:col :let={lot} label="유형">{lot_type_label(lot.lot_type)}</:col>
        <:col :let={lot} label="잔량">{lot.quantity}</:col>
        <:col :let={lot} label="상태"><.status_badge status={lot.status} /></:col>
        <:col :let={lot} label="계보">
          <span :if={is_nil(lot.source_operation_id)} class="text-xs text-zinc-400">원자재</span>
          <span :if={not is_nil(lot.source_operation_id)} class="text-xs text-green-600">생산</span>
        </:col>
        <:action :let={lot}>
          <.link navigate={~p"/admin/lots/#{lot.id}/genealogy"} class="text-indigo-600 hover:underline">
            계보 보기
          </.link>
        </:action>
      </.table>
    </.admin_shell>
    """
  end

  defp item_label(items, item_id) do
    case Map.get(items, item_id) do
      %{item_code: code, name: name} -> "#{code} (#{name})"
      _ -> "—"
    end
  end

  defp lot_type_label("raw"), do: "원자재"
  defp lot_type_label("semi"), do: "반제품"
  defp lot_type_label("product"), do: "제품"
  defp lot_type_label(other), do: other

  defp lot_status_label("available"), do: "가용"
  defp lot_status_label("reserved"), do: "예약"
  defp lot_status_label("produced"), do: "생산완료"
  defp lot_status_label("consumed"), do: "소비완료"
  defp lot_status_label("quarantined"), do: "격리"
  defp lot_status_label("scrapped"), do: "폐기"
  defp lot_status_label(other), do: other
end
