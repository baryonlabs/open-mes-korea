defmodule OpenMes.Charts.Geometry do
  @moduledoc """
  순수 SVG 기하 계산 모듈 (도메인/Ecto/HEEx 의존 0).

  도넛 arc path, 막대 레이아웃, 게이지 각도, 진행바 폭, 흐름 노드/엣지 좌표를
  100% 서버 측 순수 함수로 산출한다. HEEx 컴포넌트는 여기서 만든 숫자/문자열만
  `<svg>` 에 박는다(JS 계산 0, pi).

  방어 원칙(모든 함수):
    - 분모 0 / 빈 입력 / 음수 입력에서 크래시 없이 안전 기본값을 반환한다.
    - 입력은 순수 숫자(integer/float)만 받는다. Decimal→float 정규화는 호출부(컴포넌트) 책임.
    - 각도는 도(degree) 단위. SVG 좌표계(y 아래로 증가)에 맞춰 polar 변환한다.
  """

  @two_pi_deg 360.0

  # ──────────────────────────────────────────────────────────────────
  # 공통 — 극좌표 변환
  # ──────────────────────────────────────────────────────────────────

  @doc """
  극좌표(중심 cx,cy / 반지름 r / 각도 angle_deg) → 직교 좌표 {x, y}.

  각도 0도 = 12시 방향(위), 시계방향 증가. SVG 좌표계(y 아래로 증가)에 맞춘다.
  반환 좌표는 소수 둘째 자리로 반올림(SVG path 가독성).
  """
  def polar_point(cx, cy, r, angle_deg) do
    # 0도를 12시(위)로 맞추기 위해 -90도 보정.
    rad = (angle_deg - 90.0) * :math.pi() / 180.0
    {round2(cx + r * :math.cos(rad)), round2(cy + r * :math.sin(rad))}
  end

  @doc """
  도넛/원호 한 조각의 SVG path `d` 문자열.

  바깥 반지름(r_out)과 안쪽 반지름(r_in)으로 도넛 띠 모양의 닫힌 path 를 만든다.
  start_deg ~ end_deg 구간(시계방향). r_in <= 0 이면 파이(부채꼴) 모양.
  각도 폭 0 이하이면 빈 문자열("") 반환(그릴 것 없음).
  """
  def arc_path(cx, cy, r_out, r_in, start_deg, end_deg) do
    sweep = end_deg - start_deg

    cond do
      sweep <= 0.0 ->
        ""

      sweep >= @two_pi_deg ->
        # 완전한 링/원은 단일 arc 로 닫히지 않으므로 두 반원으로 분할.
        full_ring_path(cx, cy, r_out, r_in)

      true ->
        large_arc = if sweep > 180.0, do: 1, else: 0
        {ox1, oy1} = polar_point(cx, cy, r_out, start_deg)
        {ox2, oy2} = polar_point(cx, cy, r_out, end_deg)

        if r_in <= 0 do
          # 부채꼴(파이): 중심 → 바깥호 → 중심.
          "M #{f(cx)} #{f(cy)} " <>
            "L #{f(ox1)} #{f(oy1)} " <>
            "A #{f(r_out)} #{f(r_out)} 0 #{large_arc} 1 #{f(ox2)} #{f(oy2)} Z"
        else
          {ix2, iy2} = polar_point(cx, cy, r_in, end_deg)
          {ix1, iy1} = polar_point(cx, cy, r_in, start_deg)

          "M #{f(ox1)} #{f(oy1)} " <>
            "A #{f(r_out)} #{f(r_out)} 0 #{large_arc} 1 #{f(ox2)} #{f(oy2)} " <>
            "L #{f(ix2)} #{f(iy2)} " <>
            "A #{f(r_in)} #{f(r_in)} 0 #{large_arc} 0 #{f(ix1)} #{f(iy1)} Z"
        end
    end
  end

  # 완전한 도넛 링(360도)을 두 반원 arc 로 합성.
  defp full_ring_path(cx, cy, r_out, r_in) do
    seg1 = arc_path(cx, cy, r_out, r_in, 0.0, 180.0)
    seg2 = arc_path(cx, cy, r_out, r_in, 180.0, 359.999)
    String.trim(seg1 <> " " <> seg2)
  end

  # ──────────────────────────────────────────────────────────────────
  # 도넛 차트
  # ──────────────────────────────────────────────────────────────────

  @doc """
  값 리스트를 도넛 세그먼트 path 목록으로 변환한다.

  values: 숫자 리스트(음수는 0 으로 clamp). 합이 0 이면 [] 반환(호출부에서 회색 전체링 처리).
  반환: [%{path: binary, start_deg: float, end_deg: float, fraction: float}] (입력 순서 보존).
  값 0 인 세그먼트는 폭 0 이라 path == ""(빈 문자열)로 포함된다(인덱스 정합 유지).
  """
  def donut_segments(values, cx, cy, r_out, r_in) do
    safe = Enum.map(values, &max(to_num(&1), 0.0))
    total = Enum.sum(safe)

    if total <= 0.0 do
      []
    else
      {segments, _acc} =
        Enum.reduce(safe, {[], 0.0}, fn v, {acc, start} ->
          fraction = v / total
          ed = start + fraction * @two_pi_deg

          seg = %{
            path: arc_path(cx, cy, r_out, r_in, start, min(ed, 359.999)),
            start_deg: start,
            end_deg: ed,
            fraction: fraction
          }

          {[seg | acc], ed}
        end)

      Enum.reverse(segments)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 막대 차트 (스택)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  스택 막대 차트 레이아웃.

  categories: [%{label, segments: [%{value, ...}]}] — 각 카테고리는 세그먼트들의 스택.
  plot_w/plot_h: 그릴 영역(px). max: y축 최대값(전체 카테고리 스택 합의 최대). max<=0 이면 모든 막대 0.

  반환:
    %{
      bars: [%{label, x, width, segments: [원본 + %{y, height, value}]}],
      ticks: [%{value, y}],          # y축 눈금(0..max)
      max: 사용된 max,
      baseline_y: plot_h             # 바닥선 y
    }
  빈 categories → bars: [], ticks: [%{value: 0, y: plot_h}].
  """
  def bar_layout(categories, plot_w, plot_h, max) do
    categories = List.wrap(categories)
    count = length(categories)
    max = to_num(max)

    if count == 0 do
      %{bars: [], ticks: [%{value: 0.0, y: round2(plot_h)}], max: 0.0, baseline_y: round2(plot_h)}
    else
      slot_w = plot_w / count
      band = slot_w * 0.62
      pad = (slot_w - band) / 2.0
      effective_max = if max > 0.0, do: max, else: 1.0

      bars =
        categories
        |> Enum.with_index()
        |> Enum.map(fn {cat, idx} ->
          x = idx * slot_w + pad
          segs = layout_stack(Map.get(cat, :segments, []), plot_h, effective_max, max)

          %{
            label: Map.get(cat, :label, ""),
            x: round2(x),
            width: round2(band),
            segments: segs
          }
        end)

      %{
        bars: bars,
        ticks: tick_positions(max, plot_h),
        max: max,
        baseline_y: round2(plot_h)
      }
    end
  end

  # 한 카테고리 안에서 세그먼트를 바닥부터 위로 쌓는다.
  defp layout_stack(segments, plot_h, effective_max, real_max) do
    {laid, _top} =
      Enum.reduce(List.wrap(segments), {[], 0.0}, fn seg, {acc, stacked} ->
        v = max(to_num(Map.get(seg, :value, 0)), 0.0)

        height = if real_max > 0.0, do: v / effective_max * plot_h, else: 0.0
        y = plot_h - stacked - height

        out = Map.merge(seg, %{y: round2(y), height: round2(height), value: v})
        {[out | acc], stacked + height}
      end)

    Enum.reverse(laid)
  end

  defp tick_positions(max, plot_h) when max <= 0.0,
    do: [%{value: 0.0, y: round2(plot_h)}]

  defp tick_positions(max, plot_h) do
    nice_ticks(max)
    |> Enum.map(fn t ->
      y = plot_h - t / max * plot_h
      %{value: t, y: round2(y)}
    end)
  end

  @doc """
  0 ~ max 구간을 "보기 좋은" 눈금값 리스트로 분할한다.

  max <= 0 → [0.0]. 그 외 count(기본 4) 등분의 균등 눈금(0 포함, max 포함).
  """
  def nice_ticks(max, count \\ 4)

  def nice_ticks(max, _count) when max <= 0, do: [0.0]

  def nice_ticks(max, count) when count >= 1 do
    max = to_num(max)
    step = max / count
    Enum.map(0..count, fn i -> round2(i * step) end)
  end

  # ──────────────────────────────────────────────────────────────────
  # 게이지 (반원)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  반원 게이지 arc 계산.

  value_0_1: 0..1 비율(범위 밖이면 clamp). start_deg ~ end_deg: 게이지 스윕(예: -90 ~ 90).
  반환: %{bg_path, val_path, needle: {x, y}, value: clamped, angle_deg}.
    - bg_path: 배경(전체 스윕) 호.
    - val_path: 값에 해당하는 호.
    - needle: 값 위치의 호 끝점 좌표(바늘 끝).
  반원 게이지는 두께 있는 호로 그리므로 r 바깥/안쪽을 같이 쓴다(r 두께 = r*0.32).
  """
  def gauge_arc(value_0_1, cx, cy, r, start_deg, end_deg) do
    value = clamp(to_num(value_0_1), 0.0, 1.0)
    r_in = r - max(r * 0.32, 8.0)
    span = end_deg - start_deg
    val_end = start_deg + span * value

    %{
      bg_path: arc_path(cx, cy, r, r_in, start_deg, end_deg),
      val_path: arc_path(cx, cy, r, r_in, start_deg, val_end),
      needle: polar_point(cx, cy, r, val_end),
      value: value,
      angle_deg: round2(val_end)
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # 진행바
  # ──────────────────────────────────────────────────────────────────

  @doc """
  진행바 채움 폭(px).

  planned <= 0 → 0.0. current/planned 를 0..1 로 clamp 후 track_w 곱.
  반환: %{width: px, fraction: 0..1, over?: 초과 여부}.
  """
  def progress_width(current, planned, track_w) do
    current = max(to_num(current), 0.0)
    planned = to_num(planned)
    track_w = max(to_num(track_w), 0.0)

    if planned <= 0.0 do
      %{width: 0.0, fraction: 0.0, over?: false}
    else
      raw = current / planned
      fraction = clamp(raw, 0.0, 1.0)
      %{width: round2(fraction * track_w), fraction: round2(raw), over?: raw > 1.0}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 흐름 다이어그램 (노드 + 엣지)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  공정 흐름 노드/엣지 좌표를 가로 배치로 산출한다.

  count: 노드 수. w/h: 캔버스, node_w/node_h: 노드 크기.
  노드를 수직 중앙에 가로 등간격 배치하고, 인접 노드 사이를 엣지(화살표 선)로 잇는다.
  count <= 0 → nodes: [], edges: []. count == 1 → 노드 1개, edges: [].

  반환: %{nodes: [%{x, y, w, h, cx, cy}], edges: [%{x1, y1, x2, y2}]}.
  """
  def flow_nodes(count, w, h, node_w, node_h) do
    count = trunc(to_num(count))

    if count <= 0 do
      %{nodes: [], edges: []}
    else
      gap = if count > 1, do: (w - count * node_w) / (count + 1), else: (w - node_w) / 2.0
      gap = max(gap, 4.0)
      y = (h - node_h) / 2.0

      nodes =
        Enum.map(0..(count - 1), fn i ->
          x = gap + i * (node_w + gap)

          %{
            x: round2(x),
            y: round2(y),
            w: round2(node_w),
            h: round2(node_h),
            cx: round2(x + node_w / 2.0),
            cy: round2(y + node_h / 2.0)
          }
        end)

      edges =
        nodes
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] ->
          %{
            x1: round2(a.x + node_w),
            y1: round2(a.cy),
            x2: round2(b.x),
            y2: round2(b.cy)
          }
        end)

      %{nodes: nodes, edges: edges}
    end
  end

  @doc """
  지그재그(serpentine) 라인 노드/엣지 좌표를 산출한다.

  count 노드를 rows 행에 뱀형으로 배치한다(0행: 좌→우, 1행: 우→좌, …).
  인접 노드(index i→i+1) 엣지를 잇되, 같은 행이면 `:horizontal`, 행이 바뀌면
  `:turn`(아래로 내려가는 꺾임)으로 표기한다.

  count <= 0 → nodes: [], edges: []. rows < 1 → rows: 1(단일 행, flow_nodes 와 동형).
  마지막 행 노드 수가 부족해도 실제 노드만 배치한다(빈 칸 없음).

  반환: %{
    nodes: [%{x, y, w, h, cx, cy, row, col, index}],
    edges: [%{x1, y1, x2, y2, kind: :horizontal | :turn, from_index, to_index}]
  }
  """
  def line_nodes(count, w, h, node_w, node_h, opts \\ []) do
    count = trunc(to_num(count))
    rows = max(trunc(to_num(Keyword.get(opts, :rows, 2))), 1)

    if count <= 0 do
      %{nodes: [], edges: []}
    else
      rows = min(rows, count)
      per_row = ceil_div(count, rows)
      row_h = h / rows

      # 가로 등간격(flow_nodes gap 로직 동형 — per_row 기준).
      gap =
        if per_row > 1,
          do: (w - per_row * node_w) / (per_row + 1),
          else: (w - node_w) / 2.0

      gap = max(gap, 4.0)

      nodes =
        Enum.map(0..(count - 1), fn i ->
          row = div(i, per_row)
          col_in_row = rem(i, per_row)
          # serpentine: 홀수 행은 좌우 반전.
          col = if rem(row, 2) == 0, do: col_in_row, else: per_row - 1 - col_in_row

          x = gap + col * (node_w + gap)
          y = row * row_h + (row_h - node_h) / 2.0

          %{
            x: round2(x),
            y: round2(y),
            w: round2(node_w),
            h: round2(node_h),
            cx: round2(x + node_w / 2.0),
            cy: round2(y + node_h / 2.0),
            row: row,
            col: col,
            index: i
          }
        end)

      edges =
        nodes
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] ->
          if a.row == b.row do
            # 같은 행: 진행 방향 면끼리 잇는다(좌→우 또는 우→좌).
            {x1, x2} =
              if b.cx >= a.cx,
                do: {a.x + node_w, b.x},
                else: {a.x, b.x + node_w}

            %{
              x1: round2(x1),
              y1: round2(a.cy),
              x2: round2(x2),
              y2: round2(b.cy),
              kind: :horizontal,
              from_index: a.index,
              to_index: b.index
            }
          else
            # 행 전환: 위 노드 bottom → 아래 노드 top 꺾임(MVP는 중심 잇는 단순선).
            %{
              x1: round2(a.cx),
              y1: round2(a.y + node_h),
              x2: round2(b.cx),
              y2: round2(b.y),
              kind: :turn,
              from_index: a.index,
              to_index: b.index
            }
          end
        end)

      %{nodes: nodes, edges: edges}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  # 올림 나눗셈(per_row 계산용). divisor >= 1 보장된 상태에서 호출.
  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp to_num(n) when is_integer(n), do: n * 1.0
  defp to_num(n) when is_float(n), do: n
  defp to_num(_), do: 0.0

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp round2(n), do: Float.round(n * 1.0, 2)

  # SVG path 숫자 포맷(불필요한 .0 제거는 하지 않음 — round2 결과 그대로).
  defp f(n), do: round2(n)
end
