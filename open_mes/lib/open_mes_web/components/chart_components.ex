defmodule OpenMesWeb.ChartComponents do
  @moduledoc """
  순수 SVG 차트 컴포넌트 모듈 (stateless `Phoenix.Component`).

  외부 차트 라이브러리(Chart.js/D3 등) 0 — `OpenMes.Charts.Geometry` 순수 함수로
  좌표/path 를 계산하고 인라인 `<svg>` 로 렌더한다(pi). 데이터 집계/쿼리 금지 —
  이미 정규화된 데이터를 attr 로 받는다.

  접근성:
    - 모든 차트에 `role="img"` + `aria-label`(한국어 요약) 부여.
    - 색만으로 구분 금지 — 색 옆에 텍스트 라벨/범례/숫자 병기(색맹 대응).

  색 매핑(`chart_color/1`)은 `AdminComponents.status_badge` 의미축과 일치시킨다:
    draft=zinc, released=blue, in_progress=indigo, completed=green, cancelled=red,
    good=green, defect=red, gauge good/warn/danger.

  Decimal → float 정규화는 이 컴포넌트 경계에서 수행한다(Geometry 는 숫자만 받음).
  """
  use Phoenix.Component

  alias OpenMes.Charts.Geometry

  # ──────────────────────────────────────────────────────────────────
  # 색 매핑 — status_badge 의미축과 일치
  # ──────────────────────────────────────────────────────────────────

  @colors %{
    "draft" => "#a1a1aa",
    "released" => "#3b82f6",
    "in_progress" => "#6366f1",
    "completed" => "#22c55e",
    "cancelled" => "#ef4444",
    "good" => "#22c55e",
    "defect" => "#ef4444",
    "gauge_good" => "#22c55e",
    "gauge_warn" => "#f59e0b",
    "gauge_danger" => "#ef4444",
    "track" => "#e4e4e7",
    "muted" => "#a1a1aa"
  }

  @doc "의미 key → SVG fill 용 hex 색. 미지 key 는 zinc fallback."
  def chart_color(key) when is_atom(key), do: chart_color(Atom.to_string(key))
  def chart_color(key) when is_binary(key), do: Map.get(@colors, key, "#a1a1aa")
  def chart_color(_), do: "#a1a1aa"

  # ──────────────────────────────────────────────────────────────────
  # donut_chart — 작업지시 상태 분포 (W2)
  # ──────────────────────────────────────────────────────────────────

  attr :segments, :list, required: true, doc: "[%{key, label, value, color}] (value 0 가능)"
  attr :total, :integer, default: 0
  attr :size, :integer, default: 220
  attr :title, :string, default: nil

  def donut_chart(assigns) do
    cx = assigns.size / 2
    cy = assigns.size / 2
    r_out = assigns.size / 2 - 8
    r_in = r_out * 0.6

    values = Enum.map(assigns.segments, &normalize_num(Map.get(&1, :value, 0)))
    geo = Geometry.donut_segments(values, cx, cy, r_out, r_in)

    paths =
      assigns.segments
      |> Enum.zip(geo)
      |> Enum.map(fn {seg, g} -> Map.put(seg, :path, g.path) end)

    assigns =
      assigns
      |> assign(:cx, cx)
      |> assign(:cy, cy)
      |> assign(:r_out, r_out)
      |> assign(:r_in, r_in)
      |> assign(:paths, paths)
      |> assign(:empty?, geo == [])
      |> assign(:aria, "#{assigns.title || "상태 분포"}: 총 #{assigns.total}건")

    ~H"""
    <div class="flex flex-wrap items-center gap-4">
      <svg
        viewBox={"0 0 #{@size} #{@size}"}
        width={@size}
        height={@size}
        role="img"
        aria-label={@aria}
        class="shrink-0"
      >
        <%!-- 빈 데이터: 회색 전체 링 --%>
        <circle
          :if={@empty?}
          cx={@cx}
          cy={@cy}
          r={(@r_out + @r_in) / 2}
          fill="none"
          stroke={chart_color("track")}
          stroke-width={@r_out - @r_in}
        />
        <path :for={seg <- @paths} :if={not @empty? and seg.path != ""} d={seg.path} fill={seg.color} />
        <text x={@cx} y={@cy - 2} text-anchor="middle" class="fill-zinc-900 text-2xl font-bold">
          {@total}
        </text>
        <text x={@cx} y={@cy + 16} text-anchor="middle" class="fill-zinc-400 text-xs">건</text>
      </svg>

      <ul class="space-y-1 text-sm">
        <li :for={seg <- @segments} class="flex items-center gap-2">
          <span class="inline-block h-3 w-3 rounded-sm" style={"background-color: #{seg.color}"}></span>
          <span class="text-zinc-600">{seg.label}</span>
          <span class="ml-auto font-medium tabular-nums text-zinc-900">{normalize_int(seg.value)}</span>
        </li>
      </ul>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # bar_chart — 일별 양품/불량 스택 (W5)
  # ──────────────────────────────────────────────────────────────────

  attr :categories, :list, required: true, doc: "[%{label, segments: [%{key,label,value,color}]}]"
  attr :width, :integer, default: 640
  attr :height, :integer, default: 240
  attr :y_unit_label, :string, default: "수량"
  attr :legend, :list, default: [], doc: "[%{label, color}] 상단 범례"

  def bar_chart(assigns) do
    pad_left = 44
    pad_bottom = 28
    pad_top = 12
    plot_w = assigns.width - pad_left - 8
    plot_h = assigns.height - pad_bottom - pad_top

    max_value =
      assigns.categories
      |> Enum.map(fn c ->
        c |> Map.get(:segments, []) |> Enum.map(&normalize_num(Map.get(&1, :value, 0))) |> Enum.sum()
      end)
      |> case do
        [] -> 0.0
        list -> Enum.max(list)
      end

    # Geometry 에 넘기기 전에 세그먼트 value 를 float 로 정규화.
    norm_cats =
      Enum.map(assigns.categories, fn c ->
        segs = Enum.map(Map.get(c, :segments, []), fn s -> Map.put(s, :value, normalize_num(Map.get(s, :value, 0))) end)
        %{label: Map.get(c, :label, ""), segments: segs}
      end)

    layout = Geometry.bar_layout(norm_cats, plot_w, plot_h, max_value)

    assigns =
      assigns
      |> assign(:pad_left, pad_left)
      |> assign(:pad_top, pad_top)
      |> assign(:plot_w, plot_w)
      |> assign(:plot_h, plot_h)
      |> assign(:layout, layout)
      |> assign(:aria, "일별 #{assigns.y_unit_label} 스택 막대 차트, #{length(assigns.categories)}일")

    ~H"""
    <div>
      <div :if={@legend != []} class="mb-2 flex items-center gap-4 text-xs">
        <span :for={l <- @legend} class="flex items-center gap-1.5">
          <span class="inline-block h-2.5 w-2.5 rounded-sm" style={"background-color: #{l.color}"}></span>
          <span class="text-zinc-600">{l.label}</span>
        </span>
      </div>
      <svg viewBox={"0 0 #{@width} #{@height}"} width="100%" role="img" aria-label={@aria}>
        <g transform={"translate(#{@pad_left}, #{@pad_top})"}>
          <%!-- y축 눈금선 + 값 --%>
          <g :for={tick <- @layout.ticks}>
            <line x1="0" y1={tick.y} x2={@plot_w} y2={tick.y} stroke="#f1f1f4" stroke-width="1" />
            <text x="-6" y={tick.y + 4} text-anchor="end" class="fill-zinc-400 text-[10px]">
              {format_num(tick.value)}
            </text>
          </g>
          <%!-- 막대(스택) --%>
          <g :for={bar <- @layout.bars}>
            <rect
              :for={seg <- bar.segments}
              :if={seg.height > 0}
              x={bar.x}
              y={seg.y}
              width={bar.width}
              height={seg.height}
              fill={seg.color}
              rx="1"
            >
              <title>{bar.label} {seg.label}: {format_num(seg.value)}</title>
            </rect>
            <text
              x={bar.x + bar.width / 2}
              y={@plot_h + 16}
              text-anchor="middle"
              class="fill-zinc-500 text-[10px]"
            >
              {bar.label}
            </text>
          </g>
          <%!-- 바닥선 --%>
          <line x1="0" y1={@plot_h} x2={@plot_w} y2={@plot_h} stroke="#d4d4d8" stroke-width="1" />
        </g>
      </svg>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # gauge — 불량률 반원 게이지 (W3)
  # ──────────────────────────────────────────────────────────────────

  attr :value, :any, required: true, doc: "0..1 비율(Decimal/float). 표시 시 %."
  attr :thresholds, :map, default: %{warn: 0.05, danger: 0.1}
  attr :label, :string, default: "불량률"
  attr :width, :integer, default: 220

  def gauge(assigns) do
    width = assigns.width
    height = round(width * 0.62)
    cx = width / 2
    cy = height - 16
    r = width / 2 - 12

    value = normalize_num(assigns.value) |> clamp01()
    geo = Geometry.gauge_arc(value, cx, cy, r, -90.0, 90.0)
    level = gauge_level(value, assigns.thresholds)

    assigns =
      assigns
      |> assign(:height, height)
      |> assign(:cx, cx)
      |> assign(:cy, cy)
      |> assign(:geo, geo)
      |> assign(:level, level)
      |> assign(:color, chart_color("gauge_#{level}"))
      |> assign(:pct, value * 100)
      |> assign(:level_label, gauge_level_label(level))
      |> assign(:aria, "#{assigns.label} #{Float.round(value * 100, 1)} 퍼센트, #{gauge_level_label(level)}")

    ~H"""
    <div class="flex flex-col items-center">
      <svg viewBox={"0 0 #{@width} #{@height}"} width={@width} role="img" aria-label={@aria}>
        <path d={@geo.bg_path} fill={chart_color("track")} />
        <path :if={@geo.val_path != ""} d={@geo.val_path} fill={@color} />
        <text x={@cx} y={@cy - 6} text-anchor="middle" class="fill-zinc-900 text-2xl font-bold">
          {format_pct(@pct)}%
        </text>
      </svg>
      <div class="-mt-2 flex items-center gap-1.5 text-xs">
        <span class="inline-block h-2.5 w-2.5 rounded-full" style={"background-color: #{@color}"}></span>
        <span class="font-medium text-zinc-700">{@label}</span>
        <span class="text-zinc-400">·</span>
        <span class="text-zinc-500">{@level_label}</span>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # progress_bar — 작업지시 계획 대비 실적 (W4, 행 반복)
  # ──────────────────────────────────────────────────────────────────

  attr :label, :string, required: true, doc: "작업지시번호 + 품목"
  attr :current, :any, required: true
  attr :planned, :any, required: true
  attr :color_key, :string, default: "in_progress"
  attr :height, :integer, default: 12

  def progress_bar(assigns) do
    track_w = 1000.0
    current = normalize_num(assigns.current)
    planned = normalize_num(assigns.planned)
    geo = Geometry.progress_width(current, planned, track_w)
    pct = round(geo.fraction * 100)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:planned, planned)
      |> assign(:fill_pct, geo.width / track_w * 100)
      |> assign(:over?, geo.over?)
      |> assign(:pct, pct)
      |> assign(:color, chart_color(assigns.color_key))
      |> assign(:aria, "#{assigns.label}: 계획 대비 #{round(geo.fraction * 100)} 퍼센트")

    ~H"""
    <div class="space-y-1" role="img" aria-label={@aria}>
      <div class="flex items-center justify-between text-xs">
        <span class="truncate text-zinc-700">{@label}</span>
        <span class="shrink-0 tabular-nums text-zinc-500">
          {format_num(@current)}/{format_num(@planned)}
          <span class={[@over? && "font-semibold text-amber-600", !@over? && "text-zinc-400"]}>
            ({@pct}%)
          </span>
        </span>
      </div>
      <div class="h-3 w-full overflow-hidden rounded-full bg-zinc-100" style={"height: #{@height}px"}>
        <div
          class="h-full rounded-full transition-all"
          style={"width: #{@fill_pct}%; background-color: #{@color}"}
        >
        </div>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # flow_diagram — 공정 흐름 미니맵 (W6)
  # ──────────────────────────────────────────────────────────────────

  attr :nodes, :list, required: true, doc: "[%{id, label, good, defect, defect_rate}] (공정 순서)"
  attr :width, :integer, default: 360
  attr :height, :integer, default: 240

  def flow_diagram(assigns) do
    node_w = 96
    node_h = 64
    geo = Geometry.flow_nodes(length(assigns.nodes), assigns.width, assigns.height, node_w, node_h)

    laid =
      assigns.nodes
      |> Enum.zip(geo.nodes)
      |> Enum.map(fn {data, pos} ->
        rate = normalize_num(Map.get(data, :defect_rate, 0))
        Map.merge(pos, %{
          label: Map.get(data, :label, ""),
          good: Map.get(data, :good, 0),
          defect: Map.get(data, :defect, 0),
          border: flow_border_color(rate),
          rate_pct: Float.round(rate * 100, 1)
        })
      end)

    assigns =
      assigns
      |> assign(:laid, laid)
      |> assign(:edges, geo.edges)
      |> assign(:node_w, node_w)
      |> assign(:node_h, node_h)
      |> assign(:aria, "공정 흐름도, #{length(assigns.nodes)}개 공정")

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} width="100%" role="img" aria-label={@aria}>
      <defs>
        <marker id="flow-arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
          <polygon points="0 0, 7 3, 0 6" fill="#a1a1aa" />
        </marker>
      </defs>
      <%!-- 엣지(화살표) --%>
      <line
        :for={e <- @edges}
        x1={e.x1}
        y1={e.y1}
        x2={e.x2 - 4}
        y2={e.y2}
        stroke="#a1a1aa"
        stroke-width="1.5"
        marker-end="url(#flow-arrow)"
      />
      <%!-- 노드 --%>
      <g :for={n <- @laid}>
        <rect
          x={n.x}
          y={n.y}
          width={@node_w}
          height={@node_h}
          rx="6"
          fill="#ffffff"
          stroke={n.border}
          stroke-width="2"
        />
        <text x={n.cx} y={n.y + 22} text-anchor="middle" class="fill-zinc-800 text-xs font-medium">
          {truncate_label(n.label, 8)}
        </text>
        <text x={n.cx} y={n.y + 40} text-anchor="middle" class="fill-green-600 text-[10px]">
          양품 {format_num(n.good)}
        </text>
        <text x={n.cx} y={n.y + 54} text-anchor="middle" class="fill-red-500 text-[10px]">
          불량 {format_num(n.defect)} ({n.rate_pct}%)
        </text>
      </g>
    </svg>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # sparkline — KPI 미니 막대(7일 추세, W1)
  # ──────────────────────────────────────────────────────────────────

  attr :values, :list, required: true, doc: "숫자 리스트(7일 양품 등)"
  attr :width, :integer, default: 96
  attr :height, :integer, default: 28
  attr :color_key, :string, default: "completed"
  attr :aria_label, :string, default: "최근 추세"

  def sparkline(assigns) do
    cats = Enum.map(assigns.values, fn v -> %{label: "", segments: [%{value: normalize_num(v)}]} end)

    max_value =
      case Enum.map(assigns.values, &normalize_num/1) do
        [] -> 0.0
        list -> Enum.max(list)
      end

    layout = Geometry.bar_layout(cats, assigns.width, assigns.height, max_value)

    assigns =
      assigns
      |> assign(:layout, layout)
      |> assign(:color, chart_color(assigns.color_key))

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      role="img"
      aria-label={@aria_label}
      preserveAspectRatio="none"
    >
      <g :for={bar <- @layout.bars}>
        <rect
          :for={seg <- bar.segments}
          x={bar.x}
          y={seg.y}
          width={bar.width}
          height={max(seg.height, 0.5)}
          fill={@color}
          rx="0.5"
        />
      </g>
    </svg>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # line_chart — 시계열 추세 꺾은선(SVG) + 이상치 마커 (설계 25번 §5)
  # ──────────────────────────────────────────────────────────────────

  attr :points, :list, required: true, doc: "[%{t, v}] 다운샘플 시리즈(시각 오름차순)"
  attr :anomalies, :list, default: [], doc: "[%{t, v}] 이상치 마커(선택)"
  attr :unit, :string, default: ""
  attr :label, :string, default: "추세"
  attr :width, :integer, default: 640
  attr :height, :integer, default: 180

  @doc """
  시계열 다운샘플 시리즈를 꺾은선 + 면적 + 이상치 빨강 점으로 렌더(순수 SVG).
  외부 라이브러리 0. y축 nice_ticks 재사용. 색만 의존 금지(이상치 텍스트 병기).
  """
  def line_chart(assigns) do
    pad_l = 44
    pad_r = 12
    pad_t = 12
    pad_b = 24
    plot_w = assigns.width - pad_l - pad_r
    plot_h = assigns.height - pad_t - pad_b

    vals = assigns.points |> Enum.map(&normalize_num(&1.v))
    n = length(vals)
    max_v = if vals == [], do: 1.0, else: Enum.max(vals)
    min_v = if vals == [], do: 0.0, else: Enum.min(vals)
    # 0 을 baseline 으로 두되 음수면 min 사용. 평탄 시리즈 방어.
    y_lo = min(min_v, 0.0)
    y_hi = if max_v <= y_lo, do: y_lo + 1.0, else: max_v
    span = y_hi - y_lo

    x_at = fn i -> pad_l + if(n <= 1, do: plot_w / 2, else: plot_w * i / (n - 1)) end
    y_at = fn v -> pad_t + plot_h - (normalize_num(v) - y_lo) / span * plot_h end

    coords =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> %{x: x_at.(i), y: y_at.(p.v)} end)

    line_path =
      coords
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {c, i} -> "#{if i == 0, do: "M", else: "L"}#{f(c.x)} #{f(c.y)}" end)

    area_path =
      case coords do
        [] ->
          ""

        [first | _] ->
          base = pad_t + plot_h
          "M#{f(first.x)} #{f(base)} " <>
            Enum.map_join(coords, " ", fn c -> "L#{f(c.x)} #{f(c.y)}" end) <>
            " L#{f(List.last(coords).x)} #{f(base)} Z"
      end

    ticks = Geometry.nice_ticks(y_hi, 4)

    anomaly_pts =
      Enum.map(assigns.anomalies, fn a ->
        idx = Enum.find_index(assigns.points, &(&1.t == a.t))
        %{x: x_at.(idx || 0), y: y_at.(a.v)}
      end)

    assigns =
      assigns
      |> assign(:pad_l, pad_l)
      |> assign(:plot_h, plot_h)
      |> assign(:pad_t, pad_t)
      |> assign(:line_path, line_path)
      |> assign(:area_path, area_path)
      |> assign(:coords, coords)
      |> assign(:anomaly_pts, anomaly_pts)
      |> assign(:ticks, ticks)
      |> assign(:y_lo, y_lo)
      |> assign(:y_hi, y_hi)
      |> assign(:tick_y, fn v -> y_at.(v) end)
      |> assign(:line_color, chart_color("released"))

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      role="img"
      aria-label={"#{@label} 시계열 추세 차트, 이상치 #{length(@anomalies)}건"}
      class="max-w-full"
    >
      <%!-- y축 눈금선 + 라벨 --%>
      <g :for={t <- @ticks}>
        <line
          x1={@pad_l}
          y1={@tick_y.(t)}
          x2={@width - 12}
          y2={@tick_y.(t)}
          stroke="#e4e4e7"
          stroke-width="1"
        />
        <text x={@pad_l - 6} y={@tick_y.(t) + 3} text-anchor="end" font-size="9" fill="#71717a">
          {format_num(t)}
        </text>
      </g>

      <%!-- 면적 + 꺾은선 --%>
      <path :if={@area_path != ""} d={@area_path} fill={@line_color} fill-opacity="0.08" />
      <path :if={@line_path != ""} d={@line_path} fill="none" stroke={@line_color} stroke-width="1.5" />

      <%!-- 데이터 점 --%>
      <circle :for={c <- @coords} cx={c.x} cy={c.y} r="1.6" fill={@line_color} />

      <%!-- 이상치 마커(빨강 + 외곽 링) --%>
      <g :for={a <- @anomaly_pts}>
        <circle cx={a.x} cy={a.y} r="4" fill="none" stroke="#ef4444" stroke-width="1.5" />
        <circle cx={a.x} cy={a.y} r="2" fill="#ef4444" />
      </g>

      <%!-- 빈 상태 --%>
      <text
        :if={@coords == []}
        x={@width / 2}
        y={@height / 2}
        text-anchor="middle"
        font-size="11"
        fill="#a1a1aa"
      >
        데이터 없음
      </text>
    </svg>
    """
  end

  # SVG 좌표 반올림(소수 2자리).
  defp f(n), do: Float.round(n * 1.0, 2)

  # ──────────────────────────────────────────────────────────────────
  # line_monitor — 공장 생산라인 모니터 (10공정 지그재그 + 신호등)
  # ──────────────────────────────────────────────────────────────────

  attr :steps, :list, required: true, doc: "LineMonitor.process_steps/4 결과(§2.3)"
  attr :width, :integer, default: 980
  attr :height, :integer, default: 340
  attr :rows, :integer, default: 2, doc: "지그재그 행 수"

  def line_monitor(assigns) do
    node_w = 150
    node_h = 110
    geo = Geometry.line_nodes(length(assigns.steps), assigns.width, assigns.height, node_w, node_h, rows: assigns.rows)

    # data_status 가 :bad 인 노드(데이터 미수신)는 진입 엣지를 빨강 점선으로 표시.
    bad_data_indexes =
      assigns.steps
      |> Enum.with_index()
      |> Enum.filter(fn {s, _i} -> s.data_status == :bad end)
      |> Enum.map(fn {_s, i} -> i end)
      |> MapSet.new()

    laid =
      assigns.steps
      |> Enum.zip(geo.nodes)
      |> Enum.map(fn {s, pos} ->
        Map.merge(pos, %{
          process_code: s.process_code,
          name: s.name,
          sequence: s.sequence,
          good: normalize_int(s.good),
          defect: normalize_int(s.defect),
          rate_pct: Float.round(normalize_num(s.defect_rate) * 100, 1),
          overall: s.overall,
          overall_color: status_color(s.overall),
          overall_label: overall_label(s.overall),
          data_status: s.data_status,
          equipment_status: s.equipment_status,
          quality_status: s.quality_status
        })
      end)

    edges =
      Enum.map(geo.edges, fn e ->
        danger? = MapSet.member?(bad_data_indexes, e.to_index)
        Map.merge(e, %{danger?: danger?})
      end)

    counts = Enum.frequencies_by(assigns.steps, & &1.overall)

    assigns =
      assigns
      |> assign(:laid, laid)
      |> assign(:edges, edges)
      |> assign(:node_w, node_w)
      |> assign(:node_h, node_h)
      |> assign(:aria, "생산라인 #{length(assigns.steps)}공정: 정상 #{Map.get(counts, :green, 0)}, 주의 #{Map.get(counts, :amber, 0)}, 이상 #{Map.get(counts, :red, 0)}")

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} width="100%" role="img" aria-label={@aria}>
      <defs>
        <marker id="line-arrow" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto">
          <polygon points="0 0, 7 3, 0 6" fill="#a1a1aa" />
        </marker>
        <marker id="line-arrow-danger" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto">
          <polygon points="0 0, 7 3, 0 6" fill={chart_color("gauge_danger")} />
        </marker>
      </defs>

      <%!-- 연결 화살표: 정상=회색 실선, 데이터 미수신 하류=빨강 점선 --%>
      <line
        :for={e <- @edges}
        x1={e.x1}
        y1={e.y1}
        x2={e.x2}
        y2={e.y2}
        stroke={if e.danger?, do: chart_color("gauge_danger"), else: "#a1a1aa"}
        stroke-width="1.5"
        stroke-dasharray={if e.danger?, do: "5 4", else: "0"}
        marker-end={if e.danger?, do: "url(#line-arrow-danger)", else: "url(#line-arrow)"}
      />

      <%!-- 공정 노드 --%>
      <g :for={n <- @laid}>
        <rect
          x={n.x}
          y={n.y}
          width={@node_w}
          height={@node_h}
          rx="8"
          fill="#ffffff"
          stroke={n.overall_color}
          stroke-width="2.5"
        />
        <%!-- 상태 라벨(좌상단, 색맹 대응 텍스트) --%>
        <rect x={n.x} y={n.y} width={@node_w} height="18" rx="8" fill={n.overall_color} fill-opacity="0.12" />
        <text x={n.x + 8} y={n.y + 13} class="text-[10px] font-semibold" fill={n.overall_color}>
          {n.overall_label}
        </text>
        <text x={n.x + @node_w - 8} y={n.y + 13} text-anchor="end" class="fill-zinc-400 text-[10px]">
          {n.process_code} · {n.sequence}
        </text>

        <%!-- 공정명 --%>
        <text x={n.x + 10} y={n.y + 38} class="fill-zinc-800 text-[13px] font-medium">
          {truncate_label(n.name, 9)}
        </text>

        <%!-- 미니 신호등(SVG 원 3개: 초/노/빨, 종합 상태만 점등) --%>
        <circle cx={n.x + @node_w - 16} cy={n.y + 30} r="4.5"
          fill={if n.overall == :green, do: chart_color("gauge_good"), else: "#e4e4e7"} />
        <circle cx={n.x + @node_w - 16} cy={n.y + 42} r="4.5"
          fill={if n.overall == :amber, do: chart_color("gauge_warn"), else: "#e4e4e7"} />
        <circle cx={n.x + @node_w - 16} cy={n.y + 54} r="4.5"
          fill={if n.overall == :red, do: chart_color("gauge_danger"), else: "#e4e4e7"} />

        <%!-- 3축 상태 칩(데이터/장비/품질) --%>
        <g>
          <circle cx={n.x + 14} cy={n.y + 58} r="3.5" fill={status_color(n.data_status)} />
          <text x={n.x + 22} y={n.y + 61} class="fill-zinc-600 text-[9px]">데이터 {status_label(n.data_status)}</text>
        </g>
        <g>
          <circle cx={n.x + 14} cy={n.y + 72} r="3.5" fill={status_color(n.equipment_status)} />
          <text x={n.x + 22} y={n.y + 75} class="fill-zinc-600 text-[9px]">장비 {status_label(n.equipment_status)}</text>
        </g>
        <g>
          <circle cx={n.x + 14} cy={n.y + 86} r="3.5" fill={status_color(n.quality_status)} />
          <text x={n.x + 22} y={n.y + 89} class="fill-zinc-600 text-[9px]">품질 {status_label(n.quality_status)}</text>
        </g>

        <%!-- 처리량 --%>
        <text x={n.x + 10} y={n.y + 103} class="fill-zinc-500 text-[10px]">
          양품 {n.good} · 불량 {n.defect} ({n.rate_pct}%)
        </text>
      </g>
    </svg>
    """
  end

  @doc "공정 상태 atom → SVG fill hex(기존 chart_color 재사용, 신규 색 0)."
  def status_color(:green), do: chart_color("gauge_good")
  def status_color(:amber), do: chart_color("gauge_warn")
  def status_color(:red), do: chart_color("gauge_danger")
  def status_color(:gray), do: chart_color("muted")
  def status_color(:ok), do: chart_color("gauge_good")
  def status_color(:warn), do: chart_color("gauge_warn")
  def status_color(:bad), do: chart_color("gauge_danger")
  def status_color(:unknown), do: chart_color("muted")
  def status_color(_), do: chart_color("muted")

  defp overall_label(:green), do: "정상"
  defp overall_label(:amber), do: "주의"
  defp overall_label(:red), do: "이상"
  defp overall_label(:gray), do: "데이터없음"
  defp overall_label(_), do: "—"

  defp status_label(:ok), do: "정상"
  defp status_label(:warn), do: "주의"
  defp status_label(:bad), do: "이상"
  defp status_label(:unknown), do: "—"
  defp status_label(_), do: "—"

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼 — 정규화 / 포맷 (Decimal → 숫자 경계)
  # ──────────────────────────────────────────────────────────────────

  defp normalize_num(%Decimal{} = d), do: Decimal.to_float(d)
  defp normalize_num(n) when is_integer(n), do: n * 1.0
  defp normalize_num(n) when is_float(n), do: n
  defp normalize_num(nil), do: 0.0
  defp normalize_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp normalize_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp normalize_int(n) when is_integer(n), do: n
  defp normalize_int(n) when is_float(n), do: round(n)
  defp normalize_int(_), do: 0

  defp clamp01(v), do: v |> max(0.0) |> min(1.0)

  # 정수면 정수로, 아니면 소수 1자리로 표기(불필요한 .0 제거).
  defp format_num(n) do
    f = normalize_num(n)

    if f == Float.round(f) do
      f |> round() |> Integer.to_string()
    else
      :erlang.float_to_binary(Float.round(f, 1), decimals: 1)
    end
  end

  defp format_pct(pct), do: :erlang.float_to_binary(Float.round(pct * 1.0, 1), decimals: 1)

  defp gauge_level(value, %{warn: warn, danger: danger}) do
    cond do
      value >= danger -> "danger"
      value >= warn -> "warn"
      true -> "good"
    end
  end

  defp gauge_level(_value, _), do: "good"

  defp gauge_level_label("good"), do: "양호"
  defp gauge_level_label("warn"), do: "주의"
  defp gauge_level_label("danger"), do: "위험"

  defp flow_border_color(rate) when rate >= 0.1, do: chart_color("gauge_danger")
  defp flow_border_color(rate) when rate >= 0.05, do: chart_color("gauge_warn")
  defp flow_border_color(_), do: chart_color("gauge_good")

  defp truncate_label(label, max) when is_binary(label) do
    if String.length(label) > max, do: String.slice(label, 0, max) <> "…", else: label
  end

  defp truncate_label(label, _), do: to_string(label)
end
