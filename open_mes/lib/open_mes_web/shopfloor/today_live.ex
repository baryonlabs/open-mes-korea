defmodule OpenMesWeb.Shopfloor.TodayLive do
  @moduledoc """
  현장 — 오늘 작업 목록 LiveView (설계 §2.3, §3.3 G4).

  진행 가능한 Operation(작업지시별)을 큰 카드로 보여준다. 카드 탭 → 작업 상세.
  읽기 전용(상태 전이는 작업 상세 화면에서). 대형 터치 UX.
  """
  use OpenMesWeb.Shopfloor.ShopfloorLive

  alias OpenMes.MasterData
  alias OpenMes.Production

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "오늘 작업") |> load_cards()}
  end

  defp load_cards(socket) do
    # 진행 가능한 작업지시(released/in_progress)의 공정 중 종료되지 않은 것만 카드로.
    work_orders =
      Production.list_work_orders(%{})
      |> Enum.filter(&(&1.status in ["released", "in_progress"]))

    item_lookup =
      work_orders
      |> Enum.map(& &1.item_id)
      |> Enum.uniq()
      |> Enum.map(&{&1, MasterData.get_item(&1)})
      |> Map.new()

    cards =
      Enum.flat_map(work_orders, fn wo ->
        wo.id
        |> Production.list_operations()
        |> Enum.reject(&(&1.status in ["completed", "skipped"]))
        |> Enum.map(fn op -> %{op: op, wo: wo, item: Map.get(item_lookup, wo.item_id)} end)
      end)

    assign(socket, :cards, cards)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shopfloor_shell title="오늘 작업" current_actor={@current_actor} current_role={@current_role}>
      <.sf_empty :if={@cards == []} message="진행 가능한 작업이 없습니다." />

      <div class="space-y-4">
        <.link
          :for={card <- @cards}
          navigate={~p"/shopfloor/operations/#{card.op.id}"}
          class="block rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm hover:border-indigo-300 hover:shadow"
        >
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">{card.wo.work_order_no}</p>
              <p class="mt-1 text-2xl font-bold text-zinc-900">공정 {card.op.sequence}</p>
              <p class="mt-1 text-base text-zinc-600">
                {if card.item, do: "#{card.item.item_code} · #{card.item.name}", else: ""}
              </p>
            </div>
            <.big_status_badge status={card.op.status} />
          </div>
        </.link>
      </div>
    </.shopfloor_shell>
    """
  end
end
