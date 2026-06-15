defmodule OpenMes.Production.LineMonitorTest do
  @moduledoc """
  공정 상태 판정 순수 함수 단위 테스트(설계 §2 진리표 부록 A).

  Ecto/DB 의존 없음(process_steps/4 는 순수) — async 안전.
  5가지 시나리오 → green/amber/red/gray + line_summary 집계/병목 검증.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Production.LineMonitor

  describe "3축 + overall 판정" do
    test "정상: 실적多·불량少·active·완료 → green" do
      step = build_step(good: 190, defect: 5, rate: 0.025, count: 1, op: "completed", active: true)
      assert step.data_status == :ok
      assert step.equipment_status == :ok
      assert step.quality_status == :ok
      assert step.overall == :green
    end

    test "주의: 불량률 5~10% → amber" do
      step = build_step(good: 180, defect: 12, rate: 0.0625, count: 1, op: "completed", active: true)
      assert step.quality_status == :warn
      assert step.overall == :amber
    end

    test "품질 이상: 불량률 ≥10% → red" do
      step = build_step(good: 150, defect: 40, rate: 0.21, count: 1, op: "completed", active: true)
      assert step.quality_status == :bad
      assert step.overall == :red
    end

    test "장비 이상: active=false → red(품질 양호라도)" do
      step = build_step(good: 60, defect: 5, rate: 0.07, count: 1, op: "completed", active: false)
      assert step.equipment_status == :bad
      assert step.overall == :red
    end

    test "데이터 미수신: 실적0·op=nil·매핑無 → data :bad → red" do
      step = build_step(good: 0, defect: 0, rate: 0.0, count: 0, op: nil, active: :no_equip)
      assert step.data_status == :bad
      assert step.overall == :red
    end

    test "주의(대기): 실적0·op=ready·active → amber" do
      step = build_step(good: 0, defect: 0, rate: 0.0, count: 0, op: "ready", active: true)
      assert step.data_status == :warn
      assert step.equipment_status == :warn
      assert step.overall == :amber
    end

    test "진행중: 실적 일부 + op=running → green" do
      step = build_step(good: 90, defect: 2, rate: 0.0217, count: 1, op: "running", active: true)
      assert step.data_status == :ok
      assert step.overall == :green
    end

    test "직접 overall worst-of: 모두 unknown → gray" do
      assert LineMonitor.overall([:unknown, :unknown, :unknown]) == :gray
      assert LineMonitor.overall([:ok, :unknown, :unknown]) == :green
      assert LineMonitor.overall([:ok, :warn, :ok]) == :amber
      assert LineMonitor.overall([:ok, :bad, :warn]) == :red
    end
  end

  describe "quality_status 임계" do
    test "경계값" do
      assert LineMonitor.quality_status(0, 0.0) == :unknown
      assert LineMonitor.quality_status(100, 0.049) == :ok
      assert LineMonitor.quality_status(100, 0.05) == :warn
      assert LineMonitor.quality_status(100, 0.099) == :warn
      assert LineMonitor.quality_status(100, 0.10) == :bad
    end
  end

  describe "line_summary/1" do
    test "데모 라인 집계: green/amber/red 수 + 병목 + 라인 불량률" do
      steps =
        process_steps([
          step_input("P01", "자재투입", 1),
          step_input("P03", "사출", 2),
          step_input("P05", "취출", 3),
          step_input("P07", "후가공", 4)
        ],
        %{
          "P01" => perf(190, 5, 0.025, 1),
          "P03" => perf(150, 40, 0.21, 1),
          "P05" => perf(180, 12, 0.0625, 1),
          "P07" => perf(60, 5, 0.077, 1)
        },
        %{
          "P01" => %{active: true, name: "자재투입기", equipment_code: "EQ-P01"},
          "P03" => %{active: true, name: "사출기", equipment_code: "EQ-P03"},
          "P05" => %{active: true, name: "취출로봇", equipment_code: "EQ-P05"},
          "P07" => %{active: false, name: "트리밍기", equipment_code: "EQ-P07"}
        },
        %{"P01" => "completed", "P03" => "completed", "P05" => "completed", "P07" => "completed"})

      summary = LineMonitor.line_summary(steps)

      assert summary.total_processes == 4
      assert summary.green == 1
      assert summary.amber == 1
      # P03(품질 red) + P07(장비 red) = 2
      assert summary.red == 2
      # 병목 = 불량률 최대(P03 0.21)
      assert summary.bottleneck_process_code == "P03"
      assert summary.operating_rate == 1.0
      assert summary.line_defect_rate > 0.0
    end

    test "빈 라인 방어(0 나눗셈)" do
      summary = LineMonitor.line_summary([])
      assert summary.total_processes == 0
      assert summary.operating_rate == 0.0
      assert summary.line_defect_rate == 0.0
      assert summary.bottleneck_process_code == nil
    end
  end

  # ── 헬퍼 ──────────────────────────────────────────────────────────

  defp build_step(opts) do
    code = "P01"

    equip_map =
      case Keyword.fetch!(opts, :active) do
        :no_equip -> %{}
        bool -> %{code => %{active: bool, name: "설비", equipment_code: "EQ-P01"}}
      end

    [step] =
      process_steps(
        [step_input(code, "테스트", 1)],
        %{code => perf(opts[:good], opts[:defect], opts[:rate], opts[:count])},
        equip_map,
        %{code => opts[:op]}
      )

    step
  end

  defp process_steps(processes, by_process, equip, op_status),
    do: LineMonitor.process_steps(processes, by_process, equip, op_status)

  defp step_input(code, name, seq),
    do: %{process_id: code, process_code: code, name: name, sequence: seq}

  defp perf(good, defect, rate, count) do
    g = good || 0
    d = defect || 0

    %{
      good_quantity: Decimal.new(g),
      defect_quantity: Decimal.new(d),
      total: Decimal.new(g + d),
      defect_rate: rate || 0.0,
      result_count: count || 0
    }
  end
end
