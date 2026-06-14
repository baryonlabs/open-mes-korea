defmodule OpenMes.ProductionTest do
  @moduledoc """
  WorkOrder 상태 머신 + Production 컨텍스트 단위/통합 테스트.

  검증 대상(qa-auditor 대비):
    - 상태 머신 허용/불허 전이
    - 정상 전이 4종 성공 + 상태/타임스탬프
    - 불법 전이 거부(422 흐름용 changeset 에러)
    - 각 쓰기마다 AuditLog 1건 생성(action 명 일치)
    - release 시 outbox_events 1건(work_order.released)
    - 전이 실패 시 AuditLog/Outbox 롤백(Multi 원자성)
    - draft 외 상태에서 update 거부
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Audit.AuditLog
  alias OpenMes.Outbox.Event
  alias OpenMes.Production
  alias OpenMes.Production.WorkOrder
  alias OpenMes.Production.WorkOrderStateMachine, as: SM
  alias OpenMes.Repo

  @actor "tester-01"

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "work_order_no" => "WO-#{System.unique_integer([:positive])}",
        "item_id" => Ecto.UUID.generate(),
        "planned_quantity" => "100"
      },
      overrides
    )
  end

  defp create_wo(overrides \\ %{}) do
    {:ok, wo} = Production.create_work_order(valid_attrs(overrides), @actor)
    wo
  end

  defp audit_count(action),
    do: Repo.aggregate(from(a in AuditLog, where: a.action == ^action), :count)

  defp outbox_count(event_type),
    do: Repo.aggregate(from(e in Event, where: e.event_type == ^event_type), :count)

  # ── 상태 머신 (순수 함수) ──────────────────────────────────

  describe "WorkOrderStateMachine" do
    test "허용 전이는 true" do
      assert SM.can_transition?("draft", "released")
      assert SM.can_transition?("draft", "cancelled")
      assert SM.can_transition?("released", "in_progress")
      assert SM.can_transition?("released", "cancelled")
      assert SM.can_transition?("in_progress", "completed")
      assert SM.can_transition?("in_progress", "cancelled")
    end

    test "불허 전이는 false" do
      refute SM.can_transition?("draft", "in_progress")
      refute SM.can_transition?("draft", "completed")
      refute SM.can_transition?("released", "completed")
      refute SM.can_transition?("completed", "released")
      refute SM.can_transition?("cancelled", "released")
      refute SM.can_transition?("completed", "cancelled")
    end

    test "종료 상태는 전이 불가" do
      assert SM.allowed_from("completed") == []
      assert SM.allowed_from("cancelled") == []
    end
  end

  # ── 생성 ───────────────────────────────────────────────────

  describe "create_work_order/2" do
    test "항상 draft 로 생성되고 AuditLog(work_order.create) 1건 생성" do
      {:ok, wo} = Production.create_work_order(valid_attrs(), @actor)

      assert wo.status == "draft"
      assert audit_count("work_order.create") == 1

      [log] = Repo.all(from a in AuditLog, where: a.action == "work_order.create")
      assert log.actor_id == @actor
      assert log.resource_type == "work_order"
      assert log.resource_id == wo.id
      assert is_nil(log.before)
      assert log.after["status"] == "draft"
    end

    test "클라이언트가 status 를 보내도 draft 로 강제" do
      {:ok, wo} = Production.create_work_order(valid_attrs(%{"status" => "completed"}), @actor)
      assert wo.status == "draft"
    end

    test "work_order_no 중복은 거부(422 changeset)되고 AuditLog 미생성" do
      attrs = valid_attrs()
      {:ok, _} = Production.create_work_order(attrs, @actor)

      assert {:error, %Ecto.Changeset{} = cs} = Production.create_work_order(attrs, @actor)
      assert errors_on(cs)[:work_order_no]
      # 첫 생성분 1건만 존재
      assert audit_count("work_order.create") == 1
    end

    test "planned_quantity 0 이하는 거부" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Production.create_work_order(valid_attrs(%{"planned_quantity" => "0"}), @actor)

      assert errors_on(cs)[:planned_quantity]
    end
  end

  # ── 정상 전이 ──────────────────────────────────────────────

  describe "정상 상태 전이" do
    test "release: draft → released, released_at 기록, AuditLog + outbox 이벤트 생성" do
      wo = create_wo()

      {:ok, released} = Production.release_work_order(wo.id, @actor)

      assert released.status == "released"
      assert released.released_at
      assert audit_count("work_order.release") == 1
      assert outbox_count("work_order.released") == 1

      [event] = Repo.all(Event)
      assert event.aggregate_id == wo.id
      assert event.payload["work_order_no"] == wo.work_order_no
      assert event.status == "pending"
    end

    test "start: released → in_progress, started_at 기록, outbox 이벤트 없음" do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)

      {:ok, started} = Production.start_work_order(wo.id, @actor)

      assert started.status == "in_progress"
      assert started.started_at
      assert audit_count("work_order.start") == 1
      # MVP: release 외 전이는 outbox 이벤트 미발행
      assert Repo.aggregate(Event, :count) == 1
    end

    test "complete: in_progress → completed, completed_at 기록" do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)
      {:ok, _} = Production.start_work_order(wo.id, @actor)

      {:ok, completed} = Production.complete_work_order(wo.id, @actor)

      assert completed.status == "completed"
      assert completed.completed_at
      assert audit_count("work_order.complete") == 1
    end

    test "cancel: draft → cancelled, cancelled_at 기록" do
      wo = create_wo()

      {:ok, cancelled} = Production.cancel_work_order(wo.id, @actor)

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_at
      assert audit_count("work_order.cancel") == 1
    end
  end

  # ── 불법 전이 거부 ─────────────────────────────────────────

  describe "불법 상태 전이 거부" do
    test "draft → in_progress 거부" do
      wo = create_wo()
      assert {:error, %Ecto.Changeset{} = cs} = Production.start_work_order(wo.id, @actor)
      assert errors_on(cs)[:status]
    end

    test "completed → release 거부" do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)
      {:ok, _} = Production.start_work_order(wo.id, @actor)
      {:ok, _} = Production.complete_work_order(wo.id, @actor)

      assert {:error, %Ecto.Changeset{}} = Production.release_work_order(wo.id, @actor)
    end

    test "cancelled 에서 어떤 전이도 거부" do
      wo = create_wo()
      {:ok, _} = Production.cancel_work_order(wo.id, @actor)

      assert {:error, %Ecto.Changeset{}} = Production.release_work_order(wo.id, @actor)
      assert {:error, %Ecto.Changeset{}} = Production.start_work_order(wo.id, @actor)
    end
  end

  # ── 멱등(no-op) 전이 거부 (qa-auditor 1.5 보강) ──────────────
  #
  # to == from 인 멱등 호출이 cast "변경 없음" 으로 전이 검증을 우회하던 버그 회귀 방지.
  # (a) 이미 released 인 WO 에 release 재호출 거부
  # (b) completed(종료) 상태에서 어떤 전이도 거부
  describe "멱등(동일 상태) 전이 거부" do
    test "이미 released 인 WO 에 release 재호출 거부 + 타임스탬프/AuditLog 불변" do
      wo = create_wo()
      {:ok, released} = Production.release_work_order(wo.id, @actor)
      first_released_at = released.released_at

      audit_before = audit_count("work_order.release")

      # released → released 멱등 호출은 거부되어야 한다.
      assert {:error, %Ecto.Changeset{} = cs} = Production.release_work_order(wo.id, @actor)
      assert errors_on(cs)[:status]

      # 거부되었으므로 released_at 덮어쓰기 없음 + AuditLog 누적 없음.
      reloaded = Repo.get(WorkOrder, wo.id)
      assert reloaded.released_at == first_released_at
      assert audit_count("work_order.release") == audit_before
    end

    test "completed(종료) 상태에서 complete 재호출 등 어떤 전이도 거부" do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)
      {:ok, _} = Production.start_work_order(wo.id, @actor)
      {:ok, completed} = Production.complete_work_order(wo.id, @actor)
      first_completed_at = completed.completed_at

      # completed → completed 멱등 호출 거부
      assert {:error, %Ecto.Changeset{} = cs} = Production.complete_work_order(wo.id, @actor)
      assert errors_on(cs)[:status]

      # completed → 다른 전이도 모두 거부 (종료 상태 불변식)
      assert {:error, %Ecto.Changeset{}} = Production.release_work_order(wo.id, @actor)
      assert {:error, %Ecto.Changeset{}} = Production.start_work_order(wo.id, @actor)
      assert {:error, %Ecto.Changeset{}} = Production.cancel_work_order(wo.id, @actor)

      # completed_at 덮어쓰기 없음
      assert Repo.get(WorkOrder, wo.id).completed_at == first_completed_at
    end
  end

  # ── 트랜잭션 원자성(롤백) ──────────────────────────────────

  describe "Multi 원자성" do
    test "불법 전이 실패 시 AuditLog/Outbox 모두 롤백" do
      wo = create_wo()
      before_audit = Repo.aggregate(AuditLog, :count)
      before_outbox = Repo.aggregate(Event, :count)

      # draft → completed 는 불법 → 전체 롤백
      assert {:error, %Ecto.Changeset{}} = Production.complete_work_order(wo.id, @actor)

      assert Repo.aggregate(AuditLog, :count) == before_audit
      assert Repo.aggregate(Event, :count) == before_outbox
      # 원본 상태 유지
      assert Repo.get(WorkOrder, wo.id).status == "draft"
    end
  end

  # ── 미존재 ─────────────────────────────────────────────────

  test "존재하지 않는 작업지시 전이는 :not_found" do
    assert {:error, :not_found} = Production.release_work_order(Ecto.UUID.generate(), @actor)
  end

  # ── 수정 ───────────────────────────────────────────────────

  describe "update_work_order/3" do
    test "draft 상태에서 수정 허용 + AuditLog(work_order.update)" do
      wo = create_wo()

      {:ok, updated} =
        Production.update_work_order(wo.id, %{"planned_quantity" => "250"}, @actor)

      assert Decimal.equal?(updated.planned_quantity, Decimal.new("250"))
      assert audit_count("work_order.update") == 1
    end

    test "draft 외 상태에서 수정 거부" do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)

      assert {:error, %Ecto.Changeset{} = cs} =
               Production.update_work_order(wo.id, %{"planned_quantity" => "250"}, @actor)

      assert errors_on(cs)[:status]
    end
  end
end
