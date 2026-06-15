defmodule OpenMes.Charts.GeometryTest do
  @moduledoc """
  순수 SVG 기하 계산 단위 테스트.

  검증 핵심(설계 §6-1): arc 각도 합/순서, 0합 방어, max=0 ticks,
  planned<=0 progress=0, node 0/1개 edge=0, 음수/빈 입력 무붕괴.
  Ecto/DB 의존 없음(순수 함수) — async 안전.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Charts.Geometry

  describe "polar_point/4" do
    test "0도는 12시 방향(중심 위쪽)" do
      {x, y} = Geometry.polar_point(100.0, 100.0, 50.0, 0.0)
      assert_in_delta x, 100.0, 0.01
      assert_in_delta y, 50.0, 0.01
    end

    test "90도는 3시 방향(중심 오른쪽)" do
      {x, y} = Geometry.polar_point(100.0, 100.0, 50.0, 90.0)
      assert_in_delta x, 150.0, 0.01
      assert_in_delta y, 100.0, 0.01
    end
  end

  describe "arc_path/6" do
    test "각도 폭 0 이하이면 빈 문자열" do
      assert Geometry.arc_path(100, 100, 50, 30, 90.0, 90.0) == ""
      assert Geometry.arc_path(100, 100, 50, 30, 90.0, 30.0) == ""
    end

    test "정상 구간은 M/A/Z 를 포함하는 path 문자열" do
      d = Geometry.arc_path(100, 100, 50, 30, 0.0, 90.0)
      assert is_binary(d)
      assert String.starts_with?(d, "M ")
      assert String.contains?(d, "A ")
      assert String.ends_with?(d, "Z")
    end

    test "180도 초과 구간은 large-arc 플래그 1" do
      d = Geometry.arc_path(100, 100, 50, 30, 0.0, 270.0)
      # "A r r 0 1 1 ..." — large_arc=1
      assert String.contains?(d, "0 1 1")
    end

    test "완전한 360도 링도 빈 문자열이 아님" do
      d = Geometry.arc_path(100, 100, 50, 30, 0.0, 360.0)
      assert d != ""
      assert String.contains?(d, "A ")
    end
  end

  describe "donut_segments/5" do
    test "합이 0 이면 빈 리스트(0합 방어)" do
      assert Geometry.donut_segments([0, 0, 0], 100, 100, 50, 30) == []
      assert Geometry.donut_segments([], 100, 100, 50, 30) == []
    end

    test "음수는 0 으로 clamp 되어 합 0 이면 빈 리스트" do
      assert Geometry.donut_segments([-5, -1], 100, 100, 50, 30) == []
    end

    test "세그먼트 각도가 0~360 을 빈틈없이 채우고 순서 보존" do
      segs = Geometry.donut_segments([1, 1, 2], 100, 100, 50, 30)
      assert length(segs) == 3

      # 첫 시작 0, 마지막 끝 360.
      assert_in_delta hd(segs).start_deg, 0.0, 0.01
      assert_in_delta List.last(segs).end_deg, 360.0, 0.01

      # 인접 세그먼트 연속(앞 end == 뒤 start).
      [a, b, c] = segs
      assert_in_delta a.end_deg, b.start_deg, 0.01
      assert_in_delta b.end_deg, c.start_deg, 0.01

      # 분수 합 = 1.
      total_fraction = Enum.sum(Enum.map(segs, & &1.fraction))
      assert_in_delta total_fraction, 1.0, 0.001

      # 값 2 인 세그먼트가 값 1 짜리의 2배 분수.
      assert_in_delta c.fraction, a.fraction * 2, 0.001
    end

    test "값 0 세그먼트는 빈 path 로 포함(인덱스 정합)" do
      segs = Geometry.donut_segments([1, 0, 1], 100, 100, 50, 30)
      assert length(segs) == 3
      assert Enum.at(segs, 1).path == ""
      assert Enum.at(segs, 1).fraction == 0.0
    end
  end

  describe "nice_ticks/2" do
    test "max <= 0 이면 [0.0]" do
      assert Geometry.nice_ticks(0) == [0.0]
      assert Geometry.nice_ticks(-10) == [0.0]
    end

    test "양수 max 는 0 포함 균등 눈금(기본 4등분)" do
      ticks = Geometry.nice_ticks(100)
      assert hd(ticks) == 0.0
      assert List.last(ticks) == 100.0
      assert length(ticks) == 5
    end
  end

  describe "bar_layout/4" do
    test "빈 categories 면 막대 없음 + 바닥 tick 만" do
      layout = Geometry.bar_layout([], 600, 200, 0)
      assert layout.bars == []
      assert layout.ticks == [%{value: 0.0, y: 200.0}]
    end

    test "max 0 이면 모든 세그먼트 height 0(빈 데이터 방어)" do
      cats = [%{label: "월", segments: [%{value: 0, key: :good}]}]
      layout = Geometry.bar_layout(cats, 600, 200, 0)
      [bar] = layout.bars
      assert Enum.all?(bar.segments, &(&1.height == 0.0))
    end

    test "스택 세그먼트는 바닥부터 위로 쌓이고 높이 비례" do
      cats = [%{label: "월", segments: [%{value: 80, key: :good}, %{value: 20, key: :defect}]}]
      layout = Geometry.bar_layout(cats, 600, 200, 100)
      [bar] = layout.bars
      [good, defect] = bar.segments

      # good 80/100 * 200 = 160, defect 20/100 * 200 = 40.
      assert_in_delta good.height, 160.0, 0.01
      assert_in_delta defect.height, 40.0, 0.01

      # good 이 바닥(y = 200 - 160 = 40), defect 가 그 위(y = 200 - 160 - 40 = 0).
      assert_in_delta good.y, 40.0, 0.01
      assert_in_delta defect.y, 0.0, 0.01
    end

    test "막대 x 좌표가 카테고리 순서대로 증가" do
      cats = [
        %{label: "1", segments: [%{value: 10}]},
        %{label: "2", segments: [%{value: 10}]},
        %{label: "3", segments: [%{value: 10}]}
      ]

      layout = Geometry.bar_layout(cats, 600, 200, 10)
      xs = Enum.map(layout.bars, & &1.x)
      assert xs == Enum.sort(xs)
      assert length(layout.bars) == 3
    end
  end

  describe "gauge_arc/6" do
    test "값 0 이면 값 호가 빈 문자열, 배경 호는 존재" do
      g = Geometry.gauge_arc(0.0, 100, 100, 80, -90.0, 90.0)
      assert g.val_path == ""
      assert g.bg_path != ""
      assert g.value == 0.0
    end

    test "값 1 이상은 1.0 으로 clamp, 각도 = end_deg" do
      g = Geometry.gauge_arc(2.5, 100, 100, 80, -90.0, 90.0)
      assert g.value == 1.0
      assert_in_delta g.angle_deg, 90.0, 0.01
    end

    test "음수 값은 0 으로 clamp" do
      g = Geometry.gauge_arc(-0.5, 100, 100, 80, -90.0, 90.0)
      assert g.value == 0.0
    end

    test "값 0.5 는 스윕 중간 각도" do
      g = Geometry.gauge_arc(0.5, 100, 100, 80, -90.0, 90.0)
      assert_in_delta g.angle_deg, 0.0, 0.01
    end
  end

  describe "progress_width/3" do
    test "planned <= 0 이면 폭 0(0 나눗셈 방어)" do
      assert Geometry.progress_width(50, 0, 200) == %{width: 0.0, fraction: 0.0, over?: false}
      assert Geometry.progress_width(50, -10, 200) == %{width: 0.0, fraction: 0.0, over?: false}
    end

    test "절반 진행은 폭 절반" do
      r = Geometry.progress_width(50, 100, 200)
      assert_in_delta r.width, 100.0, 0.01
      assert_in_delta r.fraction, 0.5, 0.01
      refute r.over?
    end

    test "계획 초과는 폭 100% clamp + over? true" do
      r = Geometry.progress_width(150, 100, 200)
      assert_in_delta r.width, 200.0, 0.01
      assert r.over?
      assert r.fraction > 1.0
    end

    test "음수 current 는 0 으로 clamp" do
      r = Geometry.progress_width(-10, 100, 200)
      assert r.width == 0.0
    end
  end

  describe "flow_nodes/5" do
    test "노드 0개면 노드/엣지 모두 빈 리스트" do
      assert Geometry.flow_nodes(0, 360, 240, 80, 60) == %{nodes: [], edges: []}
    end

    test "노드 1개면 엣지 없음" do
      %{nodes: nodes, edges: edges} = Geometry.flow_nodes(1, 360, 240, 80, 60)
      assert length(nodes) == 1
      assert edges == []
    end

    test "노드 N개면 엣지 N-1개, x 좌표 순증가" do
      %{nodes: nodes, edges: edges} = Geometry.flow_nodes(3, 360, 240, 80, 60)
      assert length(nodes) == 3
      assert length(edges) == 2

      xs = Enum.map(nodes, & &1.x)
      assert xs == Enum.sort(xs)

      # 엣지는 앞 노드 우측에서 뒤 노드 좌측으로.
      [e1 | _] = edges
      [n1, n2 | _] = nodes
      assert_in_delta e1.x1, n1.x + 80, 0.01
      assert_in_delta e1.x2, n2.x, 0.01
    end

    test "모든 노드가 수직 중앙 정렬(같은 y)" do
      %{nodes: nodes} = Geometry.flow_nodes(4, 400, 240, 70, 50)
      ys = nodes |> Enum.map(& &1.y) |> Enum.uniq()
      assert length(ys) == 1
    end
  end

  describe "line_nodes/6 (지그재그)" do
    test "count=10, rows=2 → 노드 10개, 5+5 분배" do
      %{nodes: nodes} = Geometry.line_nodes(10, 980, 320, 150, 104, rows: 2)
      assert length(nodes) == 10
      # per_row = ceil(10/2) = 5 → 행0: 5개, 행1: 5개
      assert length(Enum.filter(nodes, &(&1.row == 0))) == 5
      assert length(Enum.filter(nodes, &(&1.row == 1))) == 5
      assert Enum.map(nodes, & &1.index) == Enum.to_list(0..9)
    end

    test "serpentine: 0행은 좌→우, 1행은 우→좌(x 방향 반전)" do
      %{nodes: nodes} = Geometry.line_nodes(10, 980, 320, 150, 104, rows: 2)
      row0 = nodes |> Enum.filter(&(&1.row == 0)) |> Enum.sort_by(& &1.index)
      row1 = nodes |> Enum.filter(&(&1.row == 1)) |> Enum.sort_by(& &1.index)
      assert Enum.map(row0, & &1.cx) == row0 |> Enum.map(& &1.cx) |> Enum.sort()
      assert Enum.map(row1, & &1.cx) == row1 |> Enum.map(& &1.cx) |> Enum.sort(:desc)
    end

    test "turn 엣지: 행 전환 지점에 정확히 1개, 나머지는 horizontal" do
      %{edges: edges} = Geometry.line_nodes(10, 980, 320, 150, 104, rows: 2)
      assert length(edges) == 9
      assert length(Enum.filter(edges, &(&1.kind == :turn))) == 1
      assert length(Enum.filter(edges, &(&1.kind == :horizontal))) == 8
    end

    test "count=0 → 빈 결과" do
      assert Geometry.line_nodes(0, 980, 320, 150, 104, rows: 2) == %{nodes: [], edges: []}
    end

    test "rows=1 → 단일 행(모든 y 동일, 전부 horizontal)" do
      %{nodes: nodes, edges: edges} = Geometry.line_nodes(5, 980, 320, 150, 104, rows: 1)
      assert length(nodes) == 5
      assert nodes |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 1
      assert Enum.all?(edges, &(&1.kind == :horizontal))
    end

    test "음수 rows → rows 1 로 보정(무붕괴)" do
      %{nodes: nodes} = Geometry.line_nodes(3, 980, 320, 150, 104, rows: -5)
      assert length(nodes) == 3
      assert nodes |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 1
    end
  end
end
