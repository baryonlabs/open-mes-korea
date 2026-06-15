defmodule OpenMesWeb.Admin.Reports.DefectsReportLive do
  @moduledoc """
  G5 조회/대시보드 — 불량 현황(운영 메뉴 통합 조회).

  DefectRecord 를 불량 유형(defect_code)별로 집계하고 기간(시작/종료일) 필터를 제공한다.
  + 기간 내 양품/불량/불량률 요약. 읽기 전용(도메인 쓰기 0).

  애드온 '불량 통계 위젯'과 별개의 코어 운영 리포트(설계 §3.3, 작업 지시).
  집계는 `OpenMes.Production.Reports` 경유. pi: 표 + CSS 막대.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Production.Reports

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "불량 현황", from: nil, to: nil)
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: parse_date(from), to: parse_date(to)) |> load()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(from: nil, to: nil) |> load()}
  end

  defp load(socket) do
    period = %{from: day_start(socket.assigns.from), to: day_end(socket.assigns.to)}
    defects = Reports.defects_by_code(period)
    summary = Reports.defect_summary(period)
    max_qty = defects |> Enum.map(& &1.quantity) |> max_decimal()

    assign(socket, defects: defects, summary: summary, max_qty: max_qty)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="불량 현황" subtitle="불량 유형별/기간별 집계(운영 통합 조회, 읽기 전용)" />

      <form phx-submit="filter" class="mb-6 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-600" for="from">시작일</label>
          <input type="date" id="from" name="from" value={to_input(@from)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1 text-sm" />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-600" for="to">종료일</label>
          <input type="date" id="to" name="to" value={to_input(@to)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1 text-sm" />
        </div>
        <.button type="submit">조회</.button>
        <button type="button" phx-click="reset"
          class="rounded-lg border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50">
          전체 기간
        </button>
      </form>

      <%!-- 기간 요약 --%>
      <section class="mb-8 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs text-zinc-500">양품 수량</p>
          <p class="mt-1 text-xl font-semibold text-zinc-900">{@summary.good_quantity}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs text-zinc-500">불량 수량</p>
          <p class="mt-1 text-xl font-semibold text-zinc-900">{@summary.defect_quantity}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs text-zinc-500">생산 수량</p>
          <p class="mt-1 text-xl font-semibold text-zinc-900">{@summary.total_quantity}</p>
        </div>
        <div class="rounded-lg border border-red-200 bg-red-50 p-4">
          <p class="text-xs text-red-600">불량률</p>
          <p class="mt-1 text-xl font-semibold text-red-700" id="defect-rate">{percent(@summary.defect_rate)}%</p>
        </div>
      </section>

      <%!-- 불량 유형별 집계 --%>
      <section>
        <h2 class="mb-3 text-base font-semibold text-zinc-900">불량 유형별 집계 ({length(@defects)}종)</h2>
        <.empty_state :if={@defects == []} message="해당 기간에 집계할 불량 기록이 없습니다." />
        <table :if={@defects != []} class="w-full text-sm" id="defect-report-table">
          <thead>
            <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500">
              <th class="py-2 pr-4">불량 유형</th>
              <th class="py-2 pr-4">수량</th>
              <th class="py-2 pr-4">비율</th>
              <th class="py-2">분포</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @defects} class="border-b border-zinc-100" id={"defect-#{row.defect_code}"}>
              <td class="py-2 pr-4 font-medium text-zinc-800">{row.defect_code}</td>
              <td class="py-2 pr-4 tabular-nums text-zinc-700">{row.quantity}</td>
              <td class="py-2 pr-4 tabular-nums text-zinc-500">{percent(row.ratio)}%</td>
              <td class="py-2">
                <div class="h-3 w-full rounded bg-zinc-100">
                  <div class="h-3 rounded bg-red-500" style={"width: #{bar_width(row.quantity, @max_qty)}%"}></div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </.admin_shell>
    """
  end

  defp percent(rate) when is_float(rate), do: :erlang.float_to_binary(rate * 100, decimals: 2)

  # max 대비 비율(%) — 0 나눗셈 방어.
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

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp day_start(nil), do: nil
  defp day_start(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")
  defp day_end(nil), do: nil
  defp day_end(%Date{} = d), do: DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")

  defp to_input(nil), do: ""
  defp to_input(%Date{} = d), do: Date.to_iso8601(d)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(nil), do: Decimal.new(0)
end
