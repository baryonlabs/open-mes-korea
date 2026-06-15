defmodule OpenMesWeb.Admin.Reports.DashboardLive do
  @moduledoc """
  G5 시각 대시보드 — 생산 현황을 순수 SVG 위젯으로 시각화한다.

  위젯 구성(설계 §2, 20_architect_visual_dashboard_design.md):
    W1 KPI 카드 4장(+sparkline) / W2 작업지시 상태 도넛 / W3 불량률 게이지 /
    W4 진행중 작업지시 진행바 / W5 일별 생산량 스택막대 / W6 공정 흐름 미니맵.

  읽기 전용(도메인 쓰기 0, AuditLog 무관). 모든 집계는 컨텍스트 읽기 함수 경유.
  실시간 갱신: connected? 일 때 30초 폴링(Process.send_after + handle_info(:refresh)
  재예약) + 수동 새로고침 버튼 + 마지막 갱신 시각.

  pi: 외부 차트 라이브러리 0 — `OpenMesWeb.ChartComponents`(순수 SVG) + 서버 계산만.
  빈 데이터(0/[]/분모0)에서 모든 위젯 무붕괴(첫 화면 기본 상태).
  """
  use OpenMesWeb.Admin.AdminLive

  import OpenMesWeb.ChartComponents

  alias OpenMes.MasterData
  alias OpenMes.Production
  alias OpenMes.Production.Reports

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(page_title: "생산 대시보드")
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_data(socket)}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  # 모든 위젯 데이터 적재(읽기 전용). 빈 데이터여도 0/[] 로 안전.
  defp load_data(socket) do
    today = Reports.today_production_summary()
    wo_counts = Reports.work_order_status_counts()
    daily = Reports.daily_production_series(7)
    defect = Reports.defect_summary()
    by_process = Reports.production_by_process()
    in_progress = Production.list_work_orders(%{"status" => "in_progress", "limit" => "8"})

    produced = Reports.produced_by_work_order(Enum.map(in_progress, & &1.id))
    items = MasterData.items_map(Enum.map(in_progress, & &1.item_id))
    processes = MasterData.processes_map(Enum.map(by_process, & &1.process_id))
    equipment_count = length(MasterData.list_equipment(%{}))

    socket
    |> assign(today: today)
    |> assign(wo_counts: wo_counts)
    |> assign(daily: daily)
    |> assign(defect: defect)
    |> assign(by_process: by_process)
    |> assign(in_progress: in_progress)
    |> assign(produced: produced)
    |> assign(items: items)
    |> assign(processes: processes)
    |> assign(equipment_count: equipment_count)
    |> assign(refreshed_at: DateTime.utc_now())
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
        title="생산 대시보드"
        subtitle="오늘 생산 현황을 SVG 차트로 시각화(읽기 전용 · 30초 자동 갱신)"
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

      <div class="grid grid-cols-12 gap-4">
        <%!-- W1 KPI 카드 행 (4장 + sparkline) --%>
        <% sparkline_values = Enum.map(@daily, & &1.good_quantity) %>
        <.kpi_card
          class="col-span-6 lg:col-span-3"
          label="오늘 생산량"
          value={format_qty(@today.total_quantity)}
          sub={"양품 #{format_qty(@today.good_quantity)} · 불량 #{format_qty(@today.defect_quantity)}"}
        >
          <.sparkline values={sparkline_values} color_key="completed" aria_label="최근 7일 양품 추세" />
        </.kpi_card>

        <.kpi_card
          class="col-span-6 lg:col-span-3"
          label="오늘 불량률"
          value={"#{format_rate(@today.defect_rate)}%"}
          sub={"불량 #{format_qty(@today.defect_quantity)}"}
        />

        <.kpi_card
          class="col-span-6 lg:col-span-3"
          label="진행중 작업지시"
          value={Integer.to_string(@today.in_progress_work_orders)}
          sub={"전체 #{@wo_counts.total}건"}
        />

        <.kpi_card
          class="col-span-6 lg:col-span-3"
          label="가동 설비"
          value={Integer.to_string(@equipment_count)}
          sub="등록 설비 수"
        />

        <%!-- W2 작업지시 상태 분포 도넛 --%>
        <section class="col-span-12 rounded-lg border border-zinc-200 bg-white p-4 lg:col-span-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">작업지시 상태 분포</h2>
          <.donut_chart segments={wo_status_segments(@wo_counts)} total={@wo_counts.total} title="작업지시 상태" />
        </section>

        <%!-- W3 종합 불량률 게이지 --%>
        <section class="col-span-12 rounded-lg border border-zinc-200 bg-white p-4 lg:col-span-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">종합 불량률</h2>
          <div class="flex items-center justify-center py-2">
            <.gauge value={@defect.defect_rate} label="종합 불량률" />
          </div>
          <p class="mt-1 text-center text-xs text-zinc-400">
            전체 기간 · 양품 {format_qty(@defect.good_quantity)} / 불량 {format_qty(@defect.defect_quantity)}
          </p>
        </section>

        <%!-- W4 진행중 작업지시 진행바 --%>
        <section class="col-span-12 rounded-lg border border-zinc-200 bg-white p-4 lg:col-span-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">진행중 작업지시 진행</h2>
          <.empty_state :if={@in_progress == []} message="진행중 작업지시가 없습니다." />
          <div :if={@in_progress != []} class="space-y-3">
            <.progress_bar
              :for={wo <- @in_progress}
              label={wo_progress_label(wo, @items)}
              current={good_of(@produced, wo.id)}
              planned={wo.planned_quantity}
              color_key="in_progress"
            />
          </div>
        </section>

        <%!-- W5 일별 생산량 스택 막대 --%>
        <section class="col-span-12 rounded-lg border border-zinc-200 bg-white p-4 lg:col-span-8">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">일별 생산량 (양품 · 불량)</h2>
          <.bar_chart
            categories={daily_categories(@daily)}
            legend={[%{label: "양품", color: chart_color("good")}, %{label: "불량", color: chart_color("defect")}]}
            y_unit_label="수량"
          />
        </section>

        <%!-- W6 공정 흐름 미니맵 --%>
        <section class="col-span-12 rounded-lg border border-zinc-200 bg-white p-4 lg:col-span-4">
          <h2 class="mb-3 text-sm font-semibold text-zinc-900">공정 흐름</h2>
          <.empty_state :if={@by_process == []} message="공정 실적이 없습니다." />
          <.flow_diagram :if={@by_process != []} nodes={process_nodes(@by_process, @processes)} />
        </section>
      </div>
    </.admin_shell>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # KPI 카드 (인라인 컴포넌트 — 호출 4곳, pi: 작은 카드 골격 1곳 정의)
  # ──────────────────────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block

  defp kpi_card(assigns) do
    ~H"""
    <div class={["rounded-lg border border-zinc-200 bg-white p-4", @class]}>
      <p class="text-xs text-zinc-500">{@label}</p>
      <p class="mt-1 text-2xl font-bold tabular-nums text-zinc-900">{@value}</p>
      <p :if={@sub} class="mt-0.5 text-xs text-zinc-400">{@sub}</p>
      <div :if={@inner_block != []} class="mt-2">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # 데이터 → 컴포넌트 입력 변환 (집계 아님 — 라벨/색 매핑만)
  # ──────────────────────────────────────────────────────────────────

  # W2: 작업지시 상태 분포 세그먼트.
  defp wo_status_segments(counts) do
    Enum.map(Reports.work_order_statuses(), fn s ->
      %{key: s, label: wo_status_label(s), value: Map.get(counts, s, 0), color: chart_color(s)}
    end)
  end

  # W5: 일별 시계열 → 스택 막대 카테고리(양품 아래, 불량 위).
  defp daily_categories(daily) do
    Enum.map(daily, fn d ->
      %{
        label: format_date(d.date),
        segments: [
          %{key: :good, label: "양품", value: d.good_quantity, color: chart_color("good")},
          %{key: :defect, label: "불량", value: d.defect_quantity, color: chart_color("defect")}
        ]
      }
    end)
  end

  # W6: 공정별 실적 → 흐름 노드(공정명 라벨 해석).
  defp process_nodes(by_process, processes) do
    Enum.map(by_process, fn p ->
      %{
        id: p.process_id,
        label: process_label(processes, p.process_id),
        good: p.good_quantity,
        defect: p.defect_quantity,
        defect_rate: p.defect_rate
      }
    end)
  end

  defp wo_progress_label(wo, items), do: "#{wo.work_order_no} · #{item_label(items, wo.item_id)}"

  defp good_of(produced, wo_id) do
    case Map.get(produced, wo_id) do
      %{good_quantity: g} -> g
      _ -> Decimal.new(0)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 라벨 / 포맷 헬퍼 (표시 전용)
  # ──────────────────────────────────────────────────────────────────

  defp wo_status_label("draft"), do: "작성중"
  defp wo_status_label("released"), do: "지시"
  defp wo_status_label("in_progress"), do: "진행중"
  defp wo_status_label("completed"), do: "완료"
  defp wo_status_label("cancelled"), do: "취소"
  defp wo_status_label(other), do: other

  defp item_label(items, item_id) do
    case Map.get(items, item_id) do
      %{item_code: code, name: name} -> "#{code} (#{name})"
      _ -> "품목 미지정"
    end
  end

  defp process_label(processes, process_id) do
    case Map.get(processes, process_id) do
      %{name: name} -> name
      _ -> "공정"
    end
  end

  # 수량 표기: 정수면 정수, 아니면 소수 1자리.
  defp format_qty(%Decimal{} = d) do
    if d == Decimal.round(d, 0) do
      d |> Decimal.round(0) |> Decimal.to_integer() |> Integer.to_string()
    else
      d |> Decimal.round(1) |> Decimal.to_string()
    end
  end

  defp format_qty(n) when is_integer(n), do: Integer.to_string(n)
  defp format_qty(_), do: "0"

  # 불량률(0..1 float) → 퍼센트 소수 1자리.
  defp format_rate(rate) when is_float(rate),
    do: :erlang.float_to_binary(Float.round(rate * 100, 1), decimals: 1)

  defp format_rate(_), do: "0.0"

  defp format_date(%Date{} = d), do: "#{d.month}/#{d.day}"
  defp format_date(_), do: ""

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: "—"
end
