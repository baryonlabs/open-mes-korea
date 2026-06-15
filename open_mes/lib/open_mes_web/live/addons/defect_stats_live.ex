defmodule OpenMesWeb.Addons.DefectStatsLive do
  @moduledoc """
  애드온 ② 불량 통계 위젯 화면(설계 §2 애드온②).

  기간 필터(시작일/종료일) → 불량 유형별 집계 표 + 텍스트 막대 차트 + 기간 불량률.
  데이터 소스는 `OpenMes.Addons.DefectStats.Stats`(읽기 전용 집계) 하나뿐이다.

  ## pi 준수

    - 외부 차트 라이브러리 **도입 안 함**. 서버 집계 + CSS width 텍스트 막대로 렌더한다.
    - 도메인 쓰기 0(AuditLog/Outbox 무관). 메타데이터/집계 조회 + 렌더뿐.

  라우트(애드온 enabled 시에만 등록 — 설계 §4.4):

      if OpenMes.Addons.DefectStats.Extension.enabled?() do
        scope "/extensions", OpenMesWeb.Addons do
          pipe_through :browser
          live "/defect-stats", DefectStatsLive, :index
        end
      end
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.DefectStats.Stats

  # 상위 N 불량 유형만 막대로 표시(pi — 화면이 길어지지 않게).
  @top_n 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "불량 통계 위젯", from: nil, to: nil)
     |> load_stats()}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply,
     socket
     |> assign(from: parse_date(from), to: parse_date(to))
     |> load_stats()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(from: nil, to: nil)
     |> load_stats()}
  end

  # 입력값(date)을 기간 필터(DateTime)로 변환해 집계한다.
  # from: 해당일 00:00:00, to: 해당일 23:59:59(종료일 포함).
  defp load_stats(socket) do
    period = %{
      from: day_start(socket.assigns.from),
      to: day_end(socket.assigns.to)
    }

    summary = Stats.summary(period)
    defects = Stats.defects_by_code(period, limit: @top_n)
    max_qty = defects |> Enum.map(& &1.quantity) |> Enum.max(fn -> 0 end)

    assign(socket, summary: summary, defects: defects, max_qty: max_qty)
  end

  # ──────────────────────────────────────────────────────────────────
  # 날짜 파싱/변환 (0/빈 입력 방어)
  # ──────────────────────────────────────────────────────────────────

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

  # 불량률(0.0..1.0) → 백분율 문자열(소수 2자리).
  defp percent(rate) when is_float(rate), do: :erlang.float_to_binary(rate * 100, decimals: 2)

  # 막대 너비(%) — max 대비 비율. max 가 0 이면 0%(0 나눗셈 방어).
  defp bar_width(_qty, 0), do: 0
  defp bar_width(qty, max) when max > 0, do: round(qty / max * 100)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">불량 통계 위젯</h1>
        <p class="mt-1 text-sm text-zinc-500">
          불량 유형별 수량/비율과 기간 불량률을 집계합니다(읽기 전용).
        </p>
      </header>

      <%!-- 기간 필터 --%>
      <form phx-submit="filter" class="mb-6 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-600" for="from">시작일</label>
          <input
            type="date"
            id="from"
            name="from"
            value={to_input(@from)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1 text-sm"
          />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-600" for="to">종료일</label>
          <input
            type="date"
            id="to"
            name="to"
            value={to_input(@to)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1 text-sm"
          />
        </div>
        <button
          type="submit"
          class="rounded-full bg-indigo-600 px-4 py-1.5 text-sm font-medium text-white"
        >
          조회
        </button>
        <button
          type="button"
          phx-click="reset"
          class="rounded-full border border-zinc-300 px-4 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
        >
          전체 기간
        </button>
      </form>

      <%!-- 기간 요약 (불량률) --%>
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
          <p class="mt-1 text-xl font-semibold text-red-700" id="defect-rate">
            {percent(@summary.defect_rate)}%
          </p>
        </div>
      </section>

      <%!-- 불량 유형별 집계 표 + 텍스트 막대 --%>
      <section>
        <h2 class="mb-3 text-base font-semibold text-zinc-900">
          불량 유형별 집계 (상위 {length(@defects)}건)
        </h2>

        <p
          :if={@defects == []}
          class="rounded-lg border border-dashed border-zinc-300 p-6 text-center text-sm text-zinc-500"
        >
          해당 기간에 집계할 불량 기록이 없습니다.
        </p>

        <table :if={@defects != []} class="w-full text-sm" id="defect-table">
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
                  <div
                    class="h-3 rounded bg-indigo-500"
                    style={"width: #{bar_width(row.quantity, @max_qty)}%"}
                  >
                  </div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
