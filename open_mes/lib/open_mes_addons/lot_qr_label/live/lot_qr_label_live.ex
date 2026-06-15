defmodule OpenMesWeb.Addons.LotQrLabelLive do
  @moduledoc """
  애드온③ LOT QR 라벨 LiveView(설계 §2.3 웹 계층).

  화면 흐름:
    1. LOT 검색(lot_no 부분 일치 + status 필터) → 결과 목록
    2. 목록에서 LOT 선택 → QR 라벨 미리보기(SVG QR + lot_no/품목/수량/상태/생성일)
    3. 인쇄(브라우저 print) — 인쇄용 라벨 레이아웃 제공

  ## 읽기 전용(필수)
    이 LiveView 는 `OpenMes.Addons.LotQrLabel` 의 **읽기 함수만** 호출한다
    (search_lots/get_lot/build_label). LOT 상태를 바꾸는 이벤트는 존재하지 않는다.
    phx 이벤트는 검색/선택/필터뿐 — 도메인 쓰기 0.

  웹 계층 네임스페이스이므로 `OpenMesWeb.Addons.*` 에 둔다(설계 §2.3).
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.LotQrLabel
  alias OpenMes.Addons.LotQrLabel.MaterialLot

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "LOT QR 라벨 생성",
       q: "",
       status_filter: "",
       statuses: MaterialLot.statuses(),
       lots: LotQrLabel.search_lots(),
       selected: nil,
       label: nil
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q} = params, socket) do
    status = Map.get(params, "status", "")
    lots = LotQrLabel.search_lots(q: q, status: status)
    {:noreply, assign(socket, q: q, status_filter: status, lots: lots)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    # 읽기 전용: 선택 = LOT 단건 조회 + 라벨 데이터 조립(상태 변경 없음).
    case LotQrLabel.get_lot(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "선택한 LOT 를 찾을 수 없습니다.")
         |> assign(selected: nil, label: nil)}

      lot ->
        {:noreply, assign(socket, selected: lot, label: LotQrLabel.build_label(lot))}
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, selected: nil, label: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">LOT QR 라벨 생성</h1>
        <p class="mt-1 text-sm text-zinc-500">
          LOT 를 검색해 QR 라벨을 미리 보고 인쇄합니다. (읽기 전용 — LOT 상태를 변경하지 않습니다.)
        </p>
      </header>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <%!-- 좌: 검색 + 목록 --%>
        <section class="print:hidden">
          <form phx-change="search" phx-submit="search" class="mb-4 flex flex-wrap gap-2">
            <input
              type="text"
              name="q"
              value={@q}
              placeholder="LOT 번호 검색"
              autocomplete="off"
              class="flex-1 rounded border border-zinc-300 px-3 py-2 text-sm"
            />
            <select name="status" class="rounded border border-zinc-300 px-2 py-2 text-sm">
              <option value="" selected={@status_filter == ""}>전체 상태</option>
              <option
                :for={s <- @statuses}
                value={s}
                selected={@status_filter == s}
              >
                {MaterialLot.status_label(s)}
              </option>
            </select>
          </form>

          <div
            :if={@lots == []}
            class="rounded-lg border border-dashed border-zinc-300 p-6 text-center text-sm text-zinc-500"
          >
            조건에 맞는 LOT 가 없습니다.
          </div>

          <ul :if={@lots != []} class="divide-y divide-zinc-100 rounded-lg border border-zinc-200">
            <li
              :for={lot <- @lots}
              id={"lot-#{lot.id}"}
              class="flex items-center justify-between gap-2 px-4 py-3"
            >
              <div>
                <p class="font-mono text-sm font-medium text-zinc-900">{lot.lot_no}</p>
                <p class="text-xs text-zinc-500">
                  {MaterialLot.status_label(lot.status)} · 수량 {format_qty(lot.quantity)}
                </p>
              </div>
              <button
                type="button"
                phx-click="select"
                phx-value-id={lot.id}
                class="rounded border border-indigo-300 px-3 py-1 text-sm font-medium text-indigo-600 hover:bg-indigo-50"
              >
                라벨
              </button>
            </li>
          </ul>
        </section>

        <%!-- 우: 라벨 미리보기 + 인쇄 --%>
        <section>
          <div
            :if={@label == nil}
            class="flex h-full min-h-40 items-center justify-center rounded-lg border border-dashed border-zinc-300 p-6 text-sm text-zinc-400 print:hidden"
          >
            왼쪽에서 LOT 를 선택하면 QR 라벨이 표시됩니다.
          </div>

          <div :if={@label != nil}>
            <div class="mb-3 flex items-center justify-between print:hidden">
              <h2 class="text-sm font-semibold text-zinc-700">라벨 미리보기</h2>
              <div class="flex gap-2">
                <button
                  type="button"
                  onclick="window.print()"
                  class="rounded bg-indigo-600 px-3 py-1 text-sm font-medium text-white hover:bg-indigo-500"
                >
                  인쇄
                </button>
                <button
                  type="button"
                  phx-click="clear"
                  class="rounded border border-zinc-300 px-3 py-1 text-sm font-medium text-zinc-600 hover:bg-zinc-50"
                >
                  닫기
                </button>
              </div>
            </div>

            <%!-- 인쇄용 라벨 레이아웃 --%>
            <div
              id="lot-label"
              class="mx-auto w-72 rounded-lg border border-zinc-800 bg-white p-4 text-zinc-900"
            >
              <div class="flex items-start gap-3">
                <div class="h-28 w-28 shrink-0">
                  {Phoenix.HTML.raw(@label.qr_svg)}
                </div>
                <div class="min-w-0 flex-1">
                  <p class="font-mono text-base font-bold leading-tight break-all">
                    {@label.lot_no}
                  </p>
                  <dl class="mt-2 space-y-0.5 text-xs">
                    <div class="flex justify-between gap-2">
                      <dt class="text-zinc-500">유형</dt>
                      <dd>{@label.lot_type || "-"}</dd>
                    </div>
                    <div class="flex justify-between gap-2">
                      <dt class="text-zinc-500">수량</dt>
                      <dd>{format_qty(@label.quantity)}</dd>
                    </div>
                    <div class="flex justify-between gap-2">
                      <dt class="text-zinc-500">상태</dt>
                      <dd>{@label.status_label}</dd>
                    </div>
                    <div class="flex justify-between gap-2">
                      <dt class="text-zinc-500">생성일</dt>
                      <dd>{format_date(@label.created_at)}</dd>
                    </div>
                  </dl>
                </div>
              </div>
              <p class="mt-2 break-all text-[10px] text-zinc-400">{@label.qr_payload}</p>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # ── 렌더 헬퍼 ────────────────────────────────────────────────────────

  defp format_qty(nil), do: "-"
  defp format_qty(%Decimal{} = q), do: Decimal.to_string(q, :normal)
  defp format_qty(q), do: to_string(q)

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_date(other), do: to_string(other)
end
