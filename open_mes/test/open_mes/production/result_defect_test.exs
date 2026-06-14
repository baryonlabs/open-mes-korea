defmodule OpenMes.Production.ResultDefectTest do
  @moduledoc """
  ProductionResult(append-only) + DefectRecord(append-only, Outbox) 테스트.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production

  @actor "actor-res"

  setup do
    {:ok, item} =
      MasterData.create_item(
        %{"item_code" => "I-#{System.unique_integer([:positive])}", "name" => "p",
          "item_type" => "product", "unit" => "EA"},
        @actor
      )

    {:ok, proc} =
      MasterData.create_process(
        %{"process_code" => "P-#{System.unique_integer([:positive])}", "name" => "절삭"},
        @actor
      )

    {:ok, wo} =
      Production.create_work_order(
        %{"work_order_no" => "WO-#{System.unique_integer([:positive])}", "item_id" => item.id,
          "planned_quantity" => 100},
        @actor
      )

    {:ok, op} =
      Production.create_operation(
        %{"work_order_id" => wo.id, "process_id" => proc.id, "sequence" => 1},
        @actor
      )

    %{op: op}
  end

  test "실적 생성 + production_result.create AuditLog", %{op: op} do
    assert {:ok, result} =
             Production.create_production_result(
               %{"operation_id" => op.id, "good_quantity" => 90, "defect_quantity" => 10},
               @actor
             )

    assert Decimal.equal?(result.good_quantity, Decimal.new(90))
    assert Repo.exists?(from l in AuditLog, where: l.action == "production_result.create" and l.resource_id == ^result.id)
    # ProductionResult 는 Outbox 미발행(문서 미정의)
    refute Repo.exists?(from e in Event, where: e.aggregate_id == ^result.id)
  end

  test "operation_id 누락 실적은 거부(코어 쓰기 필수)", %{op: _op} do
    assert {:error, cs} =
             Production.create_production_result(%{"good_quantity" => 10}, @actor)

    assert errors_on(cs).operation_id != []
  end

  test "ProductionResult 컨텍스트에 update/delete 함수가 없다(append-only)" do
    refute function_exported?(Production, :update_production_result, 3)
    refute function_exported?(Production, :delete_production_result, 1)
  end

  test "불량 기록 + defect.recorded Outbox 이벤트", %{op: op} do
    {:ok, result} =
      Production.create_production_result(
        %{"operation_id" => op.id, "good_quantity" => 80, "defect_quantity" => 20},
        @actor
      )

    assert {:ok, defect} =
             Production.record_defect(
               %{"production_result_id" => result.id, "defect_code" => "SCRATCH", "quantity" => 20},
               @actor
             )

    assert Repo.exists?(from l in AuditLog, where: l.action == "defect.record" and l.resource_id == ^defect.id)
    assert Repo.exists?(from e in Event, where: e.event_type == "defect.recorded" and e.aggregate_id == ^defect.id)
  end

  test "불량 수량 0 이하 거부", %{op: op} do
    {:ok, result} =
      Production.create_production_result(%{"operation_id" => op.id}, @actor)

    assert {:error, cs} =
             Production.record_defect(
               %{"production_result_id" => result.id, "defect_code" => "X", "quantity" => 0},
               @actor
             )

    assert errors_on(cs).quantity != []
  end
end
