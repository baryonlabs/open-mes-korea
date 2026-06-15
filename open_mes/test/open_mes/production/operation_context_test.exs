defmodule OpenMes.Production.OperationContextTest do
  @moduledoc """
  Operation 컨텍스트 통합 테스트 — 상태 전이 + AuditLog + Outbox 이벤트.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Production

  @actor "actor-op"

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

    %{wo: wo, proc: proc}
  end

  defp new_operation(wo, proc) do
    {:ok, op} =
      Production.create_operation(
        %{"work_order_id" => wo.id, "process_id" => proc.id, "sequence" => 1},
        @actor
      )

    op
  end

  test "생성은 항상 pending 이며 operation.create AuditLog 를 남긴다", %{wo: wo, proc: proc} do
    op = new_operation(wo, proc)
    assert op.status == "pending"
    assert Repo.exists?(from l in AuditLog, where: l.action == "operation.create" and l.resource_id == ^op.id)
  end

  test "정상 흐름 pending→ready→running→completed, 타임스탬프/이벤트", %{wo: wo, proc: proc} do
    op = new_operation(wo, proc)

    assert {:ok, op} = Production.ready_operation(op.id, @actor)
    assert op.status == "ready"
    # ready 는 Outbox 미발행
    refute Repo.exists?(from e in Event, where: e.aggregate_id == ^op.id)

    assert {:ok, op} = Production.start_operation(op.id, @actor)
    assert op.status == "running"
    assert op.started_at != nil
    # operation.started 이벤트 1건
    assert Repo.exists?(from e in Event, where: e.event_type == "operation.started" and e.aggregate_id == ^op.id)

    assert {:ok, op} = Production.complete_operation(op.id, @actor)
    assert op.status == "completed"
    assert op.completed_at != nil
    assert Repo.exists?(from e in Event, where: e.event_type == "operation.completed" and e.aggregate_id == ^op.id)
  end

  test "불법 전이는 거부되고 상태/이벤트 변화 없음", %{wo: wo, proc: proc} do
    op = new_operation(wo, proc)
    # pending 에서 곧장 running 불가
    assert {:error, cs} = Production.start_operation(op.id, @actor)
    assert errors_on(cs).status != []
    assert Production.get_operation(op.id).status == "pending"
    refute Repo.exists?(Event)
  end

  test "멱등(동일 상태) 전이 거부", %{wo: wo, proc: proc} do
    op = new_operation(wo, proc)
    {:ok, op} = Production.ready_operation(op.id, @actor)
    assert {:error, cs} = Production.ready_operation(op.id, @actor)
    assert Enum.any?(errors_on(cs).status, &String.contains?(&1, "동일 상태"))
  end

  test "전이 실패 시 AuditLog 롤백", %{wo: wo, proc: proc} do
    op = new_operation(wo, proc)
    create_log_count = Repo.aggregate(from(l in AuditLog, where: l.resource_id == ^op.id), :count)
    assert {:error, _} = Production.complete_operation(op.id, @actor)
    # 실패 전이는 AuditLog 를 추가하지 않는다
    assert Repo.aggregate(from(l in AuditLog, where: l.resource_id == ^op.id), :count) == create_log_count
  end
end
