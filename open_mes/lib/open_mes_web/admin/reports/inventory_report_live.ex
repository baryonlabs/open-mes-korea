defmodule OpenMesWeb.Admin.Reports.InventoryReportLive do
  @moduledoc """
  G5 조회/대시보드 — 품목별 재고 흐름.

  품목별 LOT 보유 잔량 / 생산 유입 / 소비 흐름을 집계한다(LotConsumption 기반 소비).
  + LOT 상태별 분포 요약. 읽기 전용(도메인 쓰기 0).

  집계는 `OpenMes.Lots.Reports` 경유. pi: 표 + CSS 막대.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Lots.Reports
  alias OpenMes.MasterData

  @impl true
  def mount(_params, _session, socket) do
    flow = Reports.inventory_flow_by_item()
    status_dist = Reports.lots_by_status()
    items = MasterData.items_map(Enum.map(flow, & &1.item_id))
    max_on_hand = flow |> Enum.map(& &1.on_hand_quantity) |> max_decimal()

    {:ok,
     socket
     |> assign(page_title: "재고 흐름")
     |> assign(flow: flow, status_dist: status_dist, items: items, max_on_hand: max_on_hand)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="재고 흐름" subtitle="품목별 LOT 보유/생산/소비 흐름(읽기 전용)" />

      <%!-- LOT 상태 분포 --%>
      <section class="mb-8">
        <h2 class="mb-3 text-base font-semibold text-zinc-900">LOT 상태 분포</h2>
        <.empty_state :if={@status_dist == []} message="등록된 LOT 가 없습니다." />
        <div :if={@status_dist != []} class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
          <div :for={row <- @status_dist} class="rounded-lg border border-zinc-200 bg-white p-4" id={"lot-status-#{row.status}"}>
            <p class="text-xs text-zinc-500">{lot_status_label(row.status)}</p>
            <p class="mt-1 text-xl font-semibold text-zinc-900">{row.count}<span class="ml-1 text-xs font-normal text-zinc-400">건</span></p>
            <p class="text-xs text-zinc-400">잔량 {row.quantity}</p>
          </div>
        </div>
      </section>

      <%!-- 품목별 재고 흐름 --%>
      <section>
        <h2 class="mb-3 text-base font-semibold text-zinc-900">품목별 재고 흐름</h2>
        <.empty_state :if={@flow == []} message="집계할 품목별 LOT 가 없습니다." />
        <table :if={@flow != []} class="w-full text-sm" id="inventory-flow-table">
          <thead>
            <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500">
              <th class="py-2 pr-4">품목</th>
              <th class="py-2 pr-4">LOT 수</th>
              <th class="py-2 pr-4">보유 잔량</th>
              <th class="py-2 pr-4">생산 유입</th>
              <th class="py-2 pr-4">소비</th>
              <th class="py-2">보유 분포</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @flow} class="border-b border-zinc-100" id={"inventory-#{row.item_id}"}>
              <td class="py-2 pr-4 font-medium text-zinc-800">{item_label(@items, row.item_id)}</td>
              <td class="py-2 pr-4 tabular-nums text-zinc-700">{row.lot_count}</td>
              <td class="py-2 pr-4 tabular-nums text-zinc-900">{row.on_hand_quantity}</td>
              <td class="py-2 pr-4 tabular-nums text-green-700">{row.produced_quantity}</td>
              <td class="py-2 pr-4 tabular-nums text-amber-700">{row.consumed_quantity}</td>
              <td class="py-2">
                <div class="h-3 w-full rounded bg-zinc-100">
                  <div class="h-3 rounded bg-indigo-500"
                    style={"width: #{bar_width(row.on_hand_quantity, @max_on_hand)}%"}></div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </.admin_shell>
    """
  end

  defp item_label(items, item_id) do
    case Map.get(items, item_id) do
      %{item_code: code, name: name} -> "#{code} (#{name})"
      _ -> "(미지정 품목)"
    end
  end

  defp lot_status_label("available"), do: "가용"
  defp lot_status_label("reserved"), do: "예약"
  defp lot_status_label("produced"), do: "생산완료"
  defp lot_status_label("consumed"), do: "소비완료"
  defp lot_status_label("quarantined"), do: "격리"
  defp lot_status_label("scrapped"), do: "폐기"
  defp lot_status_label(other), do: other

  defp bar_width(qty, max) do
    if Decimal.compare(to_decimal(max), Decimal.new(0)) == :eq do
      0
    else
      Decimal.div(to_decimal(qty), to_decimal(max))
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    end
  end

  defp max_decimal([]), do: Decimal.new(0)
  defp max_decimal(list), do: Enum.reduce(list, Decimal.new(0), &Decimal.max(to_decimal(&1), &2))

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(nil), do: Decimal.new(0)
end
