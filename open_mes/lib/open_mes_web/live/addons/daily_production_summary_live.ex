defmodule OpenMesWeb.Addons.DailyProductionSummaryLive do
  @moduledoc """
  애드온 ⑤ 일일 생산 요약 화면(LiveView).

  설계 §2 애드온⑤ / §2.3(웹은 `OpenMesWeb.Addons.{Addon}Live`).

  날짜 선택 → 당일 요약(작업지시 상태별 건수, 가동 작업지시 수, 총 양품/불량,
  품목별 생산량 표)을 카드/표로 렌더한다. 데이터 소스는
  `OpenMes.Addons.DailyProductionSummary.summarize/2` 하나뿐(읽기 전용).

  이 화면은 도메인 쓰기를 하지 않는다 — 집계 조회 + 렌더뿐(AuditLog/Outbox 무관).
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.DailyProductionSummary

  # 작업지시 status → 한국어 라벨(표시 순서도 이 키 순서를 따른다).
  @status_labels [
    {"draft", "작성"},
    {"released", "발행"},
    {"in_progress", "진행중"},
    {"completed", "완료"},
    {"cancelled", "취소"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(page_title: "일일 생산 요약", selected_date: today)
     |> load_summary(today)}
  end

  @impl true
  def handle_event("select_date", %{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:noreply, socket |> assign(selected_date: date) |> load_summary(date)}

      # 빈 값/잘못된 날짜는 무시(현재 선택 유지) — 방어적 처리.
      _ ->
        {:noreply, socket}
    end
  end

  # 선택일 요약을 계산해 assign. 데이터 없는 날도 빈 요약으로 안전 반환된다.
  defp load_summary(socket, date) do
    summary = DailyProductionSummary.summarize(date)
    assign(socket, summary: summary)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">일일 생산 요약</h1>
        <p class="mt-1 text-sm text-zinc-500">
          선택한 날짜의 작업지시 진행/완료 현황과 품목별 양품·불량 수량을 한눈에 봅니다.
        </p>
      </header>

      <%!-- 날짜 선택 --%>
      <form phx-change="select_date" class="mb-6 flex items-center gap-3">
        <label for="summary-date" class="text-sm font-medium text-zinc-700">날짜</label>
        <input
          type="date"
          id="summary-date"
          name="date"
          value={Date.to_iso8601(@selected_date)}
          class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm"
        />
      </form>

      <%!-- 요약 카드 --%>
      <div class="mb-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <div class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="text-xs text-zinc-500">가동 작업지시</div>
          <div class="mt-1 text-2xl font-bold text-indigo-600">
            {@summary.active_work_order_count}
          </div>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="text-xs text-zinc-500">완료 작업지시</div>
          <div class="mt-1 text-2xl font-bold text-zinc-900">
            {Map.get(@summary.work_order_counts, "completed", 0)}
          </div>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="text-xs text-zinc-500">총 양품</div>
          <div class="mt-1 text-2xl font-bold text-green-600">
            {format_decimal(@summary.total_good)}
          </div>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="text-xs text-zinc-500">총 불량</div>
          <div class="mt-1 text-2xl font-bold text-red-600">
            {format_decimal(@summary.total_defect)}
          </div>
          <div class="mt-0.5 text-xs text-zinc-400">
            불량률 {format_percent(@summary.defect_rate)}
          </div>
        </div>
      </div>

      <%!-- 작업지시 상태별 건수 --%>
      <section class="mb-6">
        <h2 class="mb-2 text-sm font-semibold text-zinc-700">작업지시 상태별</h2>
        <div class="flex flex-wrap gap-2">
          <span
            :for={{code, label} <- status_labels()}
            class="rounded-full bg-zinc-100 px-3 py-1 text-xs font-medium text-zinc-700"
          >
            {label} {Map.get(@summary.work_order_counts, code, 0)}
          </span>
        </div>
      </section>

      <%!-- 품목별 생산량 표 --%>
      <section>
        <h2 class="mb-2 text-sm font-semibold text-zinc-700">품목별 생산량 (상위)</h2>

        <div
          :if={@summary.by_item == []}
          class="rounded-lg border border-dashed border-zinc-300 p-6 text-center text-sm text-zinc-500"
        >
          선택한 날짜에 종료된 생산 실적이 없습니다.
        </div>

        <table :if={@summary.by_item != []} class="w-full text-sm">
          <thead>
            <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500">
              <th class="py-2 pr-4">품목코드</th>
              <th class="py-2 pr-4">품목명</th>
              <th class="py-2 pr-4 text-right">양품</th>
              <th class="py-2 text-right">불량</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @summary.by_item} class="border-b border-zinc-100">
              <td class="py-2 pr-4 font-mono text-xs text-zinc-700">{row.item_code || "-"}</td>
              <td class="py-2 pr-4 text-zinc-900">{row.item_name || "(미지정 품목)"}</td>
              <td class="py-2 pr-4 text-right text-green-700">{format_decimal(row.good)}</td>
              <td class="py-2 text-right text-red-700">{format_decimal(row.defect)}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <p class="mt-6 text-xs text-zinc-400">
        기준 타임존: {@summary.time_zone} · 집계 실적 {@summary.result_count}건 · 읽기 전용 요약
      </p>
    </div>
    """
  end

  # ── 렌더 헬퍼(인라인, pi) ────────────────────────────────────────────

  defp status_labels, do: @status_labels

  defp format_decimal(%Decimal{} = d) do
    # 정수면 정수로, 소수면 일반 표기(불필요한 후행 0 제거).
    if Decimal.equal?(d, Decimal.round(d, 0)) do
      d |> Decimal.round(0) |> Decimal.to_string()
    else
      Decimal.to_string(Decimal.normalize(d))
    end
  end

  defp format_decimal(other), do: to_string(other)

  defp format_percent(rate) when is_float(rate) do
    :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
  end
end
