defmodule OpenMes.Production.LineMonitor do
  @moduledoc """
  공장 생산라인 모니터 — 공정 상태 판정(순수) + 라인 조립(조회 1곳).

  설계 §2: "데이터 처리 / 장비 / 품질" 3축을 각각 :ok|:warn|:bad|:unknown 으로
  판정하고, worst-of 규칙으로 종합 신호등(:green|:amber|:red|:gray)을 산출한다.

  경계(pi):
    - `process_steps/4`, `line_summary/1`, `*_status/*`, `overall/*` : 순수(Ecto 의존 0, 테스트 대상).
    - `line_steps/1` : 라인 구성·실적·설비·op상태를 조회해 순수 판정에 넘기는 유일한 쿼리 지점.

  공정↔설비 매핑은 라인 구성 설정(`ProductionLine.steps_for_monitor/1`)이 정의한다.
  정규식(`~r/^P\\d{2}$/`)·설비 규약(`"EQ-"<>code`)을 FK 설정으로 승격(설계 22번).
  읽기 전용(도메인 쓰기 0, AuditLog 무관).
  """

  alias OpenMes.Production
  alias OpenMes.Production.Reports
  alias OpenMes.ProductionLine

  # 품질 임계(20번 게이지 thresholds 와 동일 의미축).
  @warn_rate 0.05
  @danger_rate 0.10

  # ──────────────────────────────────────────────────────────────────
  # 조립 (유일한 쿼리 지점)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  라인 공정의 상태 노드 리스트를 조회·판정해 반환한다(sequence 오름차순).

  공정·순서·설비는 라인 구성(`ProductionLine.steps_for_monitor/1`)이 정의한다
  (정규식·설비 규약 제거 — 설계 22번). `line` 은 :default(활성 첫 라인) | line_code.
  실적: `Reports.production_by_process/0`.
  op_status: `Production.latest_operation_status_by_process/1`. 빈 데이터여도 안전.
  equipment_id=nil 단계는 설비 정보 nil → 모니터에서 :unknown 안전 처리.
  """
  def line_steps(line \\ :default) do
    monitor_steps = ProductionLine.steps_for_monitor(line)
    process_ids = Enum.map(monitor_steps, & &1.process_id)

    by_process_map =
      Reports.production_by_process()
      |> Map.new(&{&1.process_id, &1})

    op_status_map = Production.latest_operation_status_by_process(process_ids)

    steps_input =
      Enum.map(monitor_steps, fn s ->
        %{process_id: s.process_id, process_code: s.process_code, name: s.name, sequence: s.sequence}
      end)

    # 라인 구성의 설비 FK → 순수 판정부 입력(process_code 키). 미지정(nil)이면 :unknown.
    equip_by_process =
      Map.new(monitor_steps, fn s ->
        equip =
          s.equipment_id &&
            %{active: s.equipment_active, name: s.equipment_name, equipment_code: nil}

        {s.process_code, equip}
      end)

    process_steps(steps_input, by_process_map, equip_by_process, op_status_map)
  end

  # ──────────────────────────────────────────────────────────────────
  # 순수 판정
  # ──────────────────────────────────────────────────────────────────

  @doc """
  공정 마스터 + 실적/설비/op상태 맵 → 라인 노드 리스트(설계 §2.3).

  입력 맵은 호출부(line_steps/1 또는 테스트)가 모아서 전달한다. Ecto 의존 0.
  """
  def process_steps(processes, by_process_map, equipment_map, op_status_map)
      when is_list(processes) do
    Enum.map(processes, fn p ->
      perf = Map.get(by_process_map, p.process_id, %{})
      equip = Map.get(equipment_map, p.process_code)
      op_status = Map.get(op_status_map, p.process_id)

      good = num(Map.get(perf, :good_quantity, 0))
      defect = num(Map.get(perf, :defect_quantity, 0))
      total = num(Map.get(perf, :total, 0))
      defect_rate = num(Map.get(perf, :defect_rate, 0))
      result_count = Map.get(perf, :result_count, 0)

      data_status = data_status(result_count, op_status)
      equipment_status = equipment_status(equip, result_count, op_status)
      quality_status = quality_status(total, defect_rate)
      overall = overall([data_status, equipment_status, quality_status])

      %{
        process_id: p.process_id,
        process_code: p.process_code,
        name: p.name,
        sequence: p.sequence,
        good: good,
        defect: defect,
        total: total,
        defect_rate: defect_rate,
        result_count: result_count,
        op_status: op_status,
        equipment_name: equip && equip.name,
        equipment_active: equip && equip.active,
        data_status: data_status,
        equipment_status: equipment_status,
        quality_status: quality_status,
        overall: overall
      }
    end)
  end

  @doc "데이터 처리 축 판정(설계 §2.2 A)."
  def data_status(result_count, op_status) do
    cond do
      result_count > 0 -> :ok
      op_status in ["running", "completed", "paused"] -> :ok
      op_status in ["ready", "pending"] -> :warn
      true -> :bad
    end
  end

  @doc "장비 축 판정(설계 §2.2 B)."
  def equipment_status(nil, _result_count, _op_status), do: :unknown

  def equipment_status(%{active: false}, _result_count, _op_status), do: :bad

  def equipment_status(%{active: true}, result_count, op_status) do
    if result_count > 0 or op_status in ["running", "completed", "paused"] do
      :ok
    else
      :warn
    end
  end

  @doc "품질 축 판정(설계 §2.2 C)."
  def quality_status(total, defect_rate) do
    cond do
      total <= 0 -> :unknown
      defect_rate >= @danger_rate -> :bad
      defect_rate >= @warn_rate -> :warn
      true -> :ok
    end
  end

  @doc "3축 → 종합 신호등(worst-of, 설계 §2.3)."
  def overall(statuses) when is_list(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :bad)) -> :red
      Enum.any?(statuses, &(&1 == :warn)) -> :amber
      Enum.any?(statuses, &(&1 == :ok)) -> :green
      true -> :gray
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 라인 요약(순수, 설계 §2.4)
  # ──────────────────────────────────────────────────────────────────

  @doc "라인 노드 리스트 → 요약 집계(가동률/상태별 수/병목/라인 불량률)."
  def line_summary(steps) when is_list(steps) do
    total = length(steps)

    line_good = steps |> Enum.map(& &1.good) |> Enum.sum()
    line_defect = steps |> Enum.map(& &1.defect) |> Enum.sum()
    line_total = line_good + line_defect

    operating = Enum.count(steps, &(&1.data_status == :ok))

    bottleneck =
      steps
      |> Enum.filter(&(&1.total > 0))
      |> Enum.max_by(& &1.defect_rate, fn -> nil end)

    %{
      total_processes: total,
      green: Enum.count(steps, &(&1.overall == :green)),
      amber: Enum.count(steps, &(&1.overall == :amber)),
      red: Enum.count(steps, &(&1.overall == :red)),
      gray: Enum.count(steps, &(&1.overall == :gray)),
      line_good: line_good,
      line_defect: line_defect,
      line_defect_rate: ratio(line_defect, line_total),
      operating_rate: ratio(operating, total),
      bottleneck_process_code: bottleneck && bottleneck.process_code
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(n) when is_integer(n), do: n * 1.0
  defp num(n) when is_float(n), do: n
  defp num(_), do: 0.0

  # 0 나눗셈 방어 비율(0..1 float).
  defp ratio(_part, total) when total <= 0, do: 0.0
  defp ratio(part, total), do: part / total
end
