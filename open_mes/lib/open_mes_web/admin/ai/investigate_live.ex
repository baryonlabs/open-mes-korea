defmodule OpenMesWeb.Admin.Ai.InvestigateLive do
  @moduledoc """
  AI 종합 조사(Level 1 Read-only) LiveView — 설계 25번 §4.

  설비/기간 선택 + 자연어 질의 → `OpenMes.Ai.Investigation.investigate/4`
  → AI 분석 요약 + 시계열 SVG 추세 + 미디어 목록 + 생산 요약(gauge/신호등) + 근거(referenced).

  안전 UI 규칙(§4.3): AI 분석은 항상 근거 + 데이터 시각화(차트/미디어)와 함께 노출.
  AI 텍스트는 "조사 결과"로 표기(보조). 모든 조사는 컨텍스트(Investigation) 경유 —
  LiveView 는 Repo 를 직접 호출하지 않는다. 쓰기 0(조사는 읽기 전용).
  """
  use OpenMesWeb.Admin.AdminLive

  import OpenMesWeb.ChartComponents

  alias OpenMes.Ai.Investigation
  alias OpenMes.MasterData

  @impl true
  def mount(_params, _session, socket) do
    equipment = MasterData.list_equipment(%{"active" => true})
    selected = List.first(equipment)

    {:ok,
     socket
     |> assign(page_title: "AI 조사")
     |> assign(equipment: equipment)
     |> assign(selected_code: selected && selected.equipment_code)
     |> assign(period: "24h")
     |> assign(query: "")
     |> assign(investigation: nil)
     |> assign(error: nil)
     |> load_history()}
  end

  @impl true
  def handle_event("select_equipment", %{"equipment_code" => code}, socket) do
    {:noreply,
     socket
     |> assign(selected_code: code, investigation: nil, error: nil)
     |> load_history()}
  end

  def handle_event("select_period", %{"period" => period}, socket) do
    {:noreply, assign(socket, period: period)}
  end

  def handle_event("investigate", %{"query" => query, "period" => period}, socket) do
    code = socket.assigns.selected_code
    actor = %{actor_id: socket.assigns.current_actor, role: socket.assigns.current_role}

    cond do
      is_nil(code) ->
        {:noreply, assign(socket, error: "먼저 설비를 선택하세요.")}

      String.trim(query) == "" ->
        {:noreply, assign(socket, error: "조사할 질의를 입력하세요.")}

      true ->
        case Investigation.investigate(code, query, actor, period: period) do
          {:ok, result} ->
            {:noreply,
             socket
             |> assign(investigation: result, query: query, period: period, error: nil)
             |> load_history()}

          {:error, :unauthorized} ->
            {:noreply, assign(socket, error: "AI 조사 권한이 없습니다.")}

          {:error, :equipment_not_found} ->
            {:noreply, assign(socket, error: "설비를 찾을 수 없습니다.")}

          {:error, reason} ->
            {:noreply, assign(socket, error: "조사 실패: #{inspect(reason)}")}
        end
    end
  end

  defp load_history(socket) do
    history =
      case socket.assigns[:selected_code] do
        nil -> []
        code -> Investigation.list_query_interactions(code, 10)
      end

    assign(socket, history: history)
  end

  # ── 렌더 헬퍼 ──

  defp provider_badge("mock"), do: "Mock 요약"
  defp provider_badge("claude"), do: "Claude"
  defp provider_badge(other), do: other || "—"

  defp media_icon("video"), do: "🎬"
  defp media_icon("image"), do: "🖼"
  defp media_icon("audio"), do: "🔊"
  defp media_icon(_), do: "📄"

  defp trend_label("rising"), do: {"상승", "text-red-700 bg-red-50"}
  defp trend_label("falling"), do: {"하락", "text-blue-700 bg-blue-50"}
  defp trend_label(_), do: {"안정", "text-zinc-700 bg-zinc-100"}

  defp overall_label(:red), do: {"이상", "bg-red-500"}
  defp overall_label(:amber), do: {"주의", "bg-amber-500"}
  defp overall_label(_), do: {"정상", "bg-green-500"}

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: Float.round(n, 2) |> Float.to_string()
  defp fmt(n), do: to_string(n)

  defp fmt_size(nil), do: "—"
  defp fmt_size(b) when is_integer(b) and b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp fmt_size(b) when is_integer(b) and b >= 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp fmt_size(b) when is_integer(b), do: "#{b} B"
  defp fmt_size(_), do: "—"

  defp fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%m-%d %H:%M")
  defp fmt_time(_), do: "—"

  defp defect_rate_float(%{process_summary: %{defect_rate: r}}) when is_number(r), do: r
  defp defect_rate_float(_), do: 0.0

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
        title="AI 조사"
        subtitle="설비/기간을 선택하고 자연어로 질의하면 AI 가 시계열·영상·생산 데이터를 종합 조사해 요약합니다. 읽기 전용 — 데이터를 변경하지 않습니다."
      />

      <.empty_state
        :if={@equipment == []}
        message="활성 설비가 없습니다. '설비' 에서 설비를 먼저 등록하세요."
      />

      <div :if={@equipment != []} class="space-y-6">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <form phx-change="select_equipment">
              <label class="mb-1 block text-sm font-medium text-zinc-700">조사 대상 설비</label>
              <select
                name="equipment_code"
                class="w-full rounded-md border-zinc-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option
                  :for={eq <- @equipment}
                  value={eq.equipment_code}
                  selected={eq.equipment_code == @selected_code}
                >
                  {eq.equipment_code} — {eq.name}
                </option>
              </select>
            </form>

            <form phx-change="select_period">
              <label class="mb-1 block text-sm font-medium text-zinc-700">조사 기간</label>
              <select
                name="period"
                class="w-full rounded-md border-zinc-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option :for={{label, val} <- Investigation.period_presets()} value={val} selected={val == @period}>
                  {label}
                </option>
              </select>
            </form>
          </div>

          <form phx-submit="investigate" class="mt-4">
            <input type="hidden" name="period" value={@period} />
            <label class="mb-1 block text-sm font-medium text-zinc-700">조사 질의 (자연어)</label>
            <textarea
              name="query"
              rows="2"
              placeholder="예) 이 설비 최근 진동 추세와 영상 이상 징후, 불량과의 상관을 조사해줘"
              class="w-full rounded-md border-zinc-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
            >{@query}</textarea>
            <div class="mt-2 flex items-center justify-between">
              <p :if={@error} class="text-sm text-red-600">{@error}</p>
              <p :if={!@error} class="text-xs text-zinc-400">
                AI 는 권한 범위의 요약 데이터만 조사합니다. 원본 변경은 없습니다.
              </p>
              <.button phx-disable-with="AI 조사 중...">조사하기</.button>
            </div>
          </form>
        </div>

        <%= if @investigation do %>
          <% ctx = @investigation.context %>
          <% res = @investigation.result %>

          <%!-- (1) AI 분석 요약 --%>
          <div class="rounded-lg border border-indigo-200 bg-indigo-50/30 p-4">
            <div class="mb-2 flex items-center gap-2">
              <h2 class="text-base font-semibold text-zinc-900">조사 결과 (AI 요약)</h2>
              <span class="rounded-full bg-zinc-200 px-2 py-0.5 text-xs font-medium text-zinc-700">
                {provider_badge(@investigation.interaction.provider)}
              </span>
            </div>
            <p class="text-sm leading-relaxed text-zinc-800">{res.analysis}</p>

            <ul :if={res.findings != []} class="mt-3 space-y-1">
              <li :for={fd <- res.findings} class="text-sm text-zinc-600">
                <span class="font-mono text-xs text-zinc-400">[{fd.kind}]</span>
                {fd[:metric] && "#{fd.metric}: "}{fd.note}
              </li>
            </ul>
          </div>

          <%!-- (2) 시계열 차트 --%>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <h2 class="mb-3 text-sm font-semibold text-zinc-700">시계열 추세 — {ctx.subject.equipment_name} ({ctx.period.label})</h2>
            <.empty_state
              :if={ctx.timeseries.metrics == []}
              message="해당 기간 시계열 측정 데이터가 없습니다."
            />
            <div :for={m <- ctx.timeseries.metrics} class="mb-5 last:mb-0">
              <div class="mb-1 flex flex-wrap items-center gap-2">
                <span class="text-sm font-medium text-zinc-800">{m.metric_key}</span>
                <% {tl, tcls} = trend_label(m.trend) %>
                <span class={["rounded px-1.5 py-0.5 text-xs font-medium", tcls]}>{tl}</span>
                <span class="text-xs text-zinc-500">평균 {fmt(m.avg)}{m.unit && " #{m.unit}"}</span>
                <span class="text-xs text-zinc-500">최소 {fmt(m.min)} / 최대 {fmt(m.max)}</span>
                <span :if={m.anomaly_count > 0} class="rounded bg-red-50 px-1.5 py-0.5 text-xs font-medium text-red-700">
                  이상치 {m.anomaly_count}건
                </span>
                <span class="text-xs text-zinc-400">측정 {m.count}건 요약</span>
              </div>
              <.line_chart
                points={m.sample}
                anomalies={[]}
                unit={m.unit || ""}
                label={m.metric_key}
                width={640}
                height={160}
              />
            </div>
          </div>

          <%!-- (3) 미디어 목록 --%>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <div class="mb-3 flex flex-wrap items-center gap-2">
              <h2 class="text-sm font-semibold text-zinc-700">미디어 ({ctx.media.total}건)</h2>
              <span class="rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600">
                영상 {ctx.media.counts_by_type["video"]} · 이미지 {ctx.media.counts_by_type["image"]} · 음성 {ctx.media.counts_by_type["audio"]}
              </span>
            </div>
            <.empty_state
              :if={ctx.media.assets == []}
              message="해당 기간 수집된 미디어가 없습니다."
            />
            <.table :if={ctx.media.assets != []} id="media-list" rows={ctx.media.assets}>
              <:col :let={a} label="종류">{media_icon(a.media_type)} {a.media_type}</:col>
              <:col :let={a} label="촬영시각">{fmt_time(a.captured_at)}</:col>
              <:col :let={a} label="크기">{fmt_size(a.file_size)}</:col>
              <:col :let={a} label="상태">{a.state}</:col>
              <:col :let={a} label="참조">
                <span class="font-mono text-xs text-zinc-500">{a.reference || "—"}</span>
              </:col>
            </.table>
          </div>

          <%!-- (4) 생산 요약 --%>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <h2 class="mb-3 text-sm font-semibold text-zinc-700">생산 요약 ({ctx.period.label})</h2>
            <div class="flex flex-wrap items-center gap-6">
              <.gauge value={defect_rate_float(ctx.production)} label="불량률" width={180} />
              <div class="space-y-1 text-sm text-zinc-700">
                <p>양품 <span class="font-semibold">{ctx.production.process_summary.good}</span></p>
                <p>불량 <span class="font-semibold text-red-600">{ctx.production.process_summary.defect}</span></p>
                <p>합계 <span class="font-semibold">{ctx.production.process_summary.total}</span></p>
                <div class="flex items-center gap-2 pt-1">
                  <% {ol, ocls} = overall_label(ctx.production.line_status.overall) %>
                  <span class={["inline-block h-3 w-3 rounded-full", ocls]}></span>
                  <span class="text-xs font-medium text-zinc-600">신호등: {ol}</span>
                </div>
              </div>
            </div>
          </div>

          <%!-- (5) 근거(referenced) — AI 분석과 항상 함께 노출 --%>
          <div class="rounded-lg border border-zinc-300 bg-zinc-50 p-4">
            <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-zinc-500">근거 (AI 가 참조한 데이터)</p>
            <p class="text-sm text-zinc-700">
              측정값 {ctx.referenced.timeseries_points_sampled}건을 {ctx.referenced.timeseries_metric_count}개 지표로 요약(다운샘플 ≤60포인트),
              미디어 {ctx.referenced.media_assets_count}건, 생산 실적·불량.
              권한: {@current_role}.
              소스: {Enum.join(ctx.referenced.sources, ", ")}.
            </p>

            <%!-- 인용 OKF 지식 문서 — RAG 근거 가시성(ai-safety 권고 보강) --%>
            <div class="mt-3 border-t border-zinc-200 pt-3">
              <p class="mb-2 text-xs font-semibold text-zinc-600">
                인용 지식 문서 ({ctx.referenced.knowledge_documents_count}건)
              </p>
              <.empty_state
                :if={Map.get(ctx.referenced, :knowledge_docs, []) == []}
                message="이 설비/공정과 연관된 지식 문서가 없습니다."
              />
              <ul :if={Map.get(ctx.referenced, :knowledge_docs, []) != []} class="space-y-1.5">
                <li
                  :for={doc <- ctx.referenced.knowledge_docs}
                  class="flex items-center gap-2 text-sm"
                >
                  <span class="rounded bg-zinc-200 px-1.5 py-0.5 text-[11px] font-medium text-zinc-700">
                    {doc.okf_type}
                  </span>
                  <span class="font-medium text-zinc-800">{doc.title}</span>
                  <span class="truncate text-xs text-zinc-400">{doc.resource}</span>
                </li>
              </ul>
            </div>
          </div>
        <% end %>

        <%!-- 조사 이력 — 감사 가시성 --%>
        <div>
          <h2 class="mb-2 text-sm font-semibold text-zinc-700">최근 AI 조사 이력</h2>
          <.empty_state :if={@history == []} message="이 설비의 AI 조사 이력이 없습니다." />
          <.table :if={@history != []} id="ai-query-history" rows={@history}>
            <:col :let={i} label="질의">{String.slice(i.prompt, 0, 40)}</:col>
            <:col :let={i} label="요청자">{i.actor_id}</:col>
            <:col :let={i} label="Provider">{provider_badge(i.provider)}</:col>
            <:col :let={i} label="시각">{Calendar.strftime(i.inserted_at, "%m-%d %H:%M")}</:col>
          </.table>
        </div>
      </div>
    </.admin_shell>
    """
  end
end
