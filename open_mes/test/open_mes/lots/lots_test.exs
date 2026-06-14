defmodule OpenMes.LotsTest do
  @moduledoc """
  Lots 컨텍스트 — LOT 생성/소비(LotConsumption 경유) + genealogy + AuditLog/Outbox.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Audit.AuditLog
  alias OpenMes.Lots
  alias OpenMes.Lots.{LotConsumption, MaterialLot}
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production

  @actor "actor-lot"

  setup do
    {:ok, raw_item} =
      MasterData.create_item(
        %{"item_code" => "RAW-#{System.unique_integer([:positive])}", "name" => "원자재",
          "item_type" => "raw", "unit" => "kg"},
        @actor
      )

    {:ok, prod_item} =
      MasterData.create_item(
        %{"item_code" => "PRD-#{System.unique_integer([:positive])}", "name" => "제품",
          "item_type" => "product", "unit" => "EA"},
        @actor
      )

    {:ok, proc} =
      MasterData.create_process(
        %{"process_code" => "P-#{System.unique_integer([:positive])}", "name" => "조립"},
        @actor
      )

    {:ok, wo} =
      Production.create_work_order(
        %{"work_order_no" => "WO-#{System.unique_integer([:positive])}", "item_id" => prod_item.id,
          "planned_quantity" => 10},
        @actor
      )

    {:ok, op} =
      Production.create_operation(
        %{"work_order_id" => wo.id, "process_id" => proc.id, "sequence" => 1},
        @actor
      )

    %{raw_item: raw_item, prod_item: prod_item, op: op}
  end

  defp receive_raw(item, qty) do
    {:ok, lot} =
      Lots.receive_lot(
        %{"lot_no" => "LOT-#{System.unique_integer([:positive])}", "item_id" => item.id,
          "lot_type" => "raw", "quantity" => qty},
        @actor
      )

    lot
  end

  test "원자재 입고는 available + material_lot.receive AuditLog", %{raw_item: raw} do
    lot = receive_raw(raw, 100)
    assert lot.status == "available"
    assert Repo.exists?(from l in AuditLog, where: l.action == "material_lot.receive" and l.resource_id == ^lot.id)
  end

  test "생산 LOT 은 produced + source_operation_id 연결 + material_lot.produced 이벤트",
       %{prod_item: prod, op: op} do
    assert {:ok, lot} =
             Lots.produce_lot(
               %{"lot_no" => "P-#{System.unique_integer([:positive])}", "item_id" => prod.id,
                 "lot_type" => "product", "quantity" => 10, "source_operation_id" => op.id},
               @actor
             )

    assert lot.status == "produced"
    assert lot.source_operation_id == op.id
    assert Repo.exists?(from e in Event, where: e.event_type == "material_lot.produced" and e.aggregate_id == ^lot.id)
  end

  describe "consume_lot — LotConsumption 경유 + 잔량/상태" do
    test "부분 소비: LotConsumption 생성 + 잔량 차감 + 상태 유지 + consumed 이벤트",
         %{raw_item: raw, op: op} do
      lot = receive_raw(raw, 100)

      assert {:ok, %LotConsumption{} = c} = Lots.consume_lot(op.id, lot.id, 30, @actor)
      assert Decimal.equal?(c.quantity, Decimal.new(30))

      reloaded = Repo.get(MaterialLot, lot.id)
      assert Decimal.equal?(reloaded.quantity, Decimal.new(70))
      assert reloaded.status == "available"

      assert Repo.exists?(from l in AuditLog, where: l.action == "lot.consume")
      assert Repo.exists?(from e in Event, where: e.event_type == "material_lot.consumed" and e.aggregate_id == ^lot.id)
    end

    test "완전 소비: 잔량 0 도달 시 consumed 로 전이", %{raw_item: raw, op: op} do
      lot = receive_raw(raw, 50)
      assert {:ok, _} = Lots.consume_lot(op.id, lot.id, 50, @actor)
      reloaded = Repo.get(MaterialLot, lot.id)
      assert Decimal.equal?(reloaded.quantity, Decimal.new(0))
      assert reloaded.status == "consumed"
    end

    test "초과 소비는 차단되고 LotConsumption/AuditLog 미생성(롤백)", %{raw_item: raw, op: op} do
      lot = receive_raw(raw, 20)
      assert {:error, :insufficient_lot_quantity} = Lots.consume_lot(op.id, lot.id, 25, @actor)
      assert Repo.aggregate(LotConsumption, :count) == 0
      # 잔량 불변
      assert Decimal.equal?(Repo.get(MaterialLot, lot.id).quantity, Decimal.new(20))
      refute Repo.exists?(from l in AuditLog, where: l.action == "lot.consume")
    end

    test "종료 상태(consumed) LOT 재소비 차단", %{raw_item: raw, op: op} do
      lot = receive_raw(raw, 10)
      {:ok, _} = Lots.consume_lot(op.id, lot.id, 10, @actor)
      assert {:error, :lot_not_consumable} = Lots.consume_lot(op.id, lot.id, 1, @actor)
    end
  end

  test "genealogy: 제품 LOT → source_operation → 투입된 원자재 LOT 추적",
       %{raw_item: raw, prod_item: prod, op: op} do
    input = receive_raw(raw, 100)
    {:ok, _consumption} = Lots.consume_lot(op.id, input.id, 40, @actor)

    {:ok, product_lot} =
      Lots.produce_lot(
        %{"lot_no" => "FG-#{System.unique_integer([:positive])}", "item_id" => prod.id,
          "lot_type" => "product", "quantity" => 5, "source_operation_id" => op.id},
        @actor
      )

    assert {:ok, geneal} = Lots.genealogy(product_lot.id)
    assert geneal.source_operation_id == op.id
    assert [%{lot: input_lot, consumption: c}] = geneal.inputs
    assert input_lot.id == input.id
    assert Decimal.equal?(c.quantity, Decimal.new(40))
  end

  test "원자재 LOT(source_operation_id nil)의 genealogy 는 빈 inputs", %{raw_item: raw} do
    lot = receive_raw(raw, 10)
    assert {:ok, %{inputs: [], source_operation_id: nil}} = Lots.genealogy(lot.id)
  end

  test "LotConsumption 컨텍스트에 수정/삭제 함수 없음(append-only)" do
    refute function_exported?(Lots, :update_consumption, 2)
    refute function_exported?(Lots, :delete_consumption, 1)
  end
end
