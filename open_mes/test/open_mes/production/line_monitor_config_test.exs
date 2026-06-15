defmodule OpenMes.Production.LineMonitorConfigTest do
  @moduledoc """
  라인 모니터 설정 전환 테스트(설계 22번) — `line_steps/1` 가 정규식 대신 라인 구성
  (ProductionLine.steps_for_monitor)을 읽어 동일 입력으로 신호등을 산출하는지 검증.

  DB 의존(설정·실적·설비). 순수 판정부는 line_monitor_test.exs 가 별도 검증.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.{Lots, MasterData, Production, ProductionLine}
  alias OpenMes.Production.LineMonitor

  @actor "tester"

  test "라인 구성 기반 신호등: 품질이상(red)·장비이상(red)·데이터미수신(red) 재현" do
    {:ok, item} =
      MasterData.create_item(%{item_code: "FP-T", name: "T 완제품", item_type: "product", unit: "EA"}, @actor)

    {:ok, p_qual} = MasterData.create_process(%{process_code: "Q01", name: "품질이상공정"}, @actor)
    {:ok, p_equip} = MasterData.create_process(%{process_code: "E01", name: "장비이상공정"}, @actor)
    {:ok, p_data} = MasterData.create_process(%{process_code: "D01", name: "데이터미수신공정"}, @actor)

    {:ok, eq_ok} = MasterData.create_equipment(%{equipment_code: "EQ-OK", name: "정상설비", active: true}, @actor)
    {:ok, eq_bad} = MasterData.create_equipment(%{equipment_code: "EQ-BAD", name: "고장설비", active: false}, @actor)

    {:ok, line} = ProductionLine.create_line(%{line_code: "LINE-T", name: "테스트 라인"}, @actor)
    {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: p_qual.id, equipment_id: eq_ok.id, sequence: 1}, @actor)
    {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: p_equip.id, equipment_id: eq_bad.id, sequence: 2}, @actor)
    {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: p_data.id, equipment_id: eq_ok.id, sequence: 3}, @actor)

    {:ok, wo} =
      Production.create_work_order(%{work_order_no: "WO-T", item_id: item.id, planned_quantity: Decimal.new("100")}, @actor)

    {:ok, _} = Production.release_work_order(wo.id, @actor)
    {:ok, _} = Production.start_work_order(wo.id, @actor)

    # Q01: 불량률 ≥10% → 품질 red. E01: 설비 active=false → 장비 red. D01: Operation 없음 → 데이터 red.
    record_result = fn process, eq, good, defect, seq ->
      {:ok, op} = Production.create_operation(%{work_order_id: wo.id, process_id: process.id, sequence: seq}, @actor)
      {:ok, _} = Production.ready_operation(op.id, @actor)
      {:ok, _} = Production.start_operation(op.id, @actor)

      {:ok, _} =
        Production.create_production_result(
          %{operation_id: op.id, equipment_id: eq.id, good_quantity: Decimal.new(good), defect_quantity: Decimal.new(defect)},
          @actor
        )

      {:ok, _} = Production.complete_operation(op.id, @actor)
    end

    record_result.(p_qual, eq_ok, 80, 20, 1)
    record_result.(p_equip, eq_bad, 100, 0, 2)
    # D01: Operation/실적 없음(데이터 미수신).

    _ = Lots

    steps = LineMonitor.line_steps(:default)
    by_code = Map.new(steps, &{&1.process_code, &1})

    assert by_code["Q01"].quality_status == :bad
    assert by_code["Q01"].overall == :red

    assert by_code["E01"].equipment_status == :bad
    assert by_code["E01"].overall == :red

    assert by_code["D01"].data_status == :bad
    assert by_code["D01"].overall == :red

    # sequence 순 보존.
    assert Enum.map(steps, & &1.process_code) == ["Q01", "E01", "D01"]
  end
end
