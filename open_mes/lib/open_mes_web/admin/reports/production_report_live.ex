defmodule OpenMesWeb.Admin.Reports.ProductionReportLive do
  @moduledoc """
  공장 생산라인 모니터 — 사출 성형 1라인(10공정) SVG 시각화(설계 21번).

  10공정을 지그재그로 배치하고 공정별 종합 신호등(정상/주의/이상/데이터없음)과
  3축 상태(데이터/장비/품질), 처리량을 표시한다. 라인 요약 바·범례·상세 표 동반.

  읽기 전용(도메인 쓰기 0, AuditLog 무관). 상태 판정·조회는 `LineMonitor` 경유.
  30초 폴링(20번 대시보드 패턴). 빈/부분 데이터에서도 라인이 그려진다.
  """
  use OpenMesWeb.Admin.AdminLive

  import OpenMesWeb.ChartComponents

  alias OpenMes.Production.LineMonitor

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(page_title: "공장 생산라인 모니터")
     |> load_line()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_line(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_line(socket)}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load_line(socket) do
    steps = LineMonitor.line_steps()
    summary = LineMonitor.line_summary(steps)

    socket
    |> assign(steps: steps, summary: summary, refreshed_at: DateTime.utc_now())
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
        title="공장 생산라인 모니터"
        subtitle="사출 성형 1라인 10공정 실시간 상태(읽기 전용 · 30초 자동 갱신)"
        roles={["production_manager", "quality_manager"]}
      >
        <:actions>
          <span class="text-xs text-zinc-400" id="refreshed-at">
            마지막 갱신 {format_time(@refreshed_at)}
          </span>
          <button
            type="button"
            phx-click="refresh"
            class="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-white px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
          >
            <.icon name="hero-arrow-path" class="h-4 w-4" /> 새로고침
          </button>
        </:actions>
      </.page_header>

      <.empty_state :if={@steps == []} message="등록된 생산라인 공정이 없습니다. (seed: 사출 라인 10공정)" />

      <div :if={@steps != []} class="space-y-4">
        <%!-- 라인 요약 바 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-4">
          <div class="flex flex-wrap items-center gap-x-8 gap-y-4">
            <div class="flex items-center">
              <.gauge value={@summary.operating_rate} label="가동률" width={180} thresholds={%{warn: 1.1, danger: 1.2}} />
            </div>

            <div class="flex flex-wrap items-center gap-3 text-sm">
              <.summary_chip color={status_color(:green)} label="정상" count={@summary.green} />
              <.summary_chip color={status_color(:amber)} label="주의" count={@summary.amber} />
              <.summary_chip color={status_color(:red)} label="이상" count={@summary.red} />
              <.summary_chip color={status_color(:gray)} label="데이터없음" count={@summary.gray} />
            </div>

            <div class="text-sm">
              <span class="text-zinc-500">병목 공정</span>
              <span class="ml-2 inline-flex items-center rounded-md bg-amber-50 px-2 py-0.5 font-semibold text-amber-700">
                {@summary.bottleneck_process_code || "—"}
              </span>
            </div>

            <div class="text-sm">
              <span class="text-zinc-500">라인 불량률</span>
              <span class="ml-2 font-semibold tabular-nums text-zinc-800">
                {format_rate(@summary.line_defect_rate)}%
              </span>
            </div>
          </div>
        </section>

        <%!-- 생산라인 흐름도(핵심) --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">생산라인 흐름도</h2>
          <.line_monitor steps={@steps} />
        </section>

        <%!-- 범례 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-4 text-xs text-zinc-600">
          <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
            <span class="font-semibold text-zinc-700">범례</span>
            <.legend_dot color={status_color(:green)} label="정상(초록)" />
            <.legend_dot color={status_color(:amber)} label="주의(노랑) — 불량률 5~10%" />
            <.legend_dot color={status_color(:red)} label="이상(빨강) — 불량률 ≥10%·장비정지·데이터미수신" />
            <.legend_dot color={status_color(:gray)} label="데이터없음(회색)" />
            <span class="flex items-center gap-1.5">
              <svg width="28" height="8"><line x1="0" y1="4" x2="28" y2="4" stroke="#a1a1aa" stroke-width="1.5" /></svg>
              정상 흐름(회색 실선)
            </span>
            <span class="flex items-center gap-1.5">
              <svg width="28" height="8"><line x1="0" y1="4" x2="28" y2="4" stroke={status_color(:red)} stroke-width="1.5" stroke-dasharray="5 4" /></svg>
              이상 흐름(빨강 점선)
            </span>
          </div>
        </section>

        <%!-- 공정 상세 표(접근성·fallback) --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">공정 상세</h2>
          <table class="w-full text-sm" id="line-detail-table">
            <thead>
              <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500">
                <th class="py-2 pr-4">공정</th>
                <th class="py-2 pr-4">양품</th>
                <th class="py-2 pr-4">불량</th>
                <th class="py-2 pr-4">불량률</th>
                <th class="py-2 pr-4">데이터</th>
                <th class="py-2 pr-4">장비</th>
                <th class="py-2 pr-4">품질</th>
                <th class="py-2">종합</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @steps} class="border-b border-zinc-100" id={"line-process-#{s.process_code}"}>
                <td class="py-2 pr-4 font-medium text-zinc-800">{s.process_code} ({s.name})</td>
                <td class="py-2 pr-4 tabular-nums text-green-700">{format_qty(s.good)}</td>
                <td class="py-2 pr-4 tabular-nums text-red-600">{format_qty(s.defect)}</td>
                <td class="py-2 pr-4 tabular-nums text-zinc-500">{format_rate(s.defect_rate)}%</td>
                <td class="py-2 pr-4"><.axis_chip status={s.data_status} /></td>
                <td class="py-2 pr-4"><.axis_chip status={s.equipment_status} /></td>
                <td class="py-2 pr-4"><.axis_chip status={s.quality_status} /></td>
                <td class="py-2"><.overall_chip overall={s.overall} /></td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </.admin_shell>
    """
  end

  # ── 내부 표시용 컴포넌트(이 화면 전용) ──────────────────────────────

  attr :color, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp summary_chip(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span class="inline-block h-3 w-3 rounded-full" style={"background-color: #{@color}"}></span>
      <span class="text-zinc-600">{@label}</span>
      <span class="font-semibold tabular-nums text-zinc-900">{@count}</span>
    </span>
    """
  end

  attr :color, :string, required: true
  attr :label, :string, required: true

  defp legend_dot(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span class="inline-block h-3 w-3 rounded-full" style={"background-color: #{@color}"}></span>
      {@label}
    </span>
    """
  end

  attr :status, :atom, required: true

  defp axis_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <span class="inline-block h-2.5 w-2.5 rounded-full" style={"background-color: #{status_color(@status)}"}></span>
      <span class="text-zinc-600">{axis_text(@status)}</span>
    </span>
    """
  end

  attr :overall, :atom, required: true

  defp overall_chip(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-semibold"
      style={"color: #{status_color(@overall)}; background-color: #{status_color(@overall)}1a"}
    >
      <span class="inline-block h-2 w-2 rounded-full" style={"background-color: #{status_color(@overall)}"}></span>
      {overall_text(@overall)}
    </span>
    """
  end

  defp axis_text(:ok), do: "정상"
  defp axis_text(:warn), do: "주의"
  defp axis_text(:bad), do: "이상"
  defp axis_text(_), do: "—"

  defp overall_text(:green), do: "정상"
  defp overall_text(:amber), do: "주의"
  defp overall_text(:red), do: "이상"
  defp overall_text(:gray), do: "데이터없음"
  defp overall_text(_), do: "—"

  # 비율(0..1 float) → 백분율 1자리 문자열.
  defp format_rate(rate) when is_float(rate),
    do: :erlang.float_to_binary(Float.round(rate * 100, 1), decimals: 1)

  defp format_rate(_), do: "0.0"

  # 표시용 수량(float → 정수 문자열).
  defp format_qty(n) when is_integer(n), do: Integer.to_string(n)
  defp format_qty(n) when is_float(n), do: n |> round() |> Integer.to_string()
  defp format_qty(_), do: "0"

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: "—"
end
