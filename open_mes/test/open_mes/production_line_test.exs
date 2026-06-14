defmodule OpenMes.ProductionLineTest do
  @moduledoc """
  생산라인 구성 컨텍스트 테스트 — CRUD + AuditLog 6 action + steps_for_monitor +
  reorder swap + delete(설계 22번). 정규식 제거 후 라인 모니터 입력 조립 검증.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.MasterData
  alias OpenMes.ProductionLine
  alias OpenMes.Audit.AuditLog
  alias OpenMes.Repo

  import Ecto.Query

  @actor "tester"

  defp seed_process(code), do: elem(MasterData.create_process(%{process_code: code, name: code}, @actor), 1)

  defp seed_equipment(code, active \\ true),
    do: elem(MasterData.create_equipment(%{equipment_code: code, name: code, active: active}, @actor), 1)

  defp audit_count(action),
    do: Repo.one(from a in AuditLog, where: a.action == ^action, select: count(a.id))

  describe "라인 CRUD + AuditLog" do
    test "생성/수정/활성토글 + AuditLog 기록" do
      assert {:ok, line} =
               ProductionLine.create_line(%{line_code: "LINE-A", name: "A 라인"}, @actor)

      assert line.active == true
      assert audit_count("production_line.create") == 1

      assert {:ok, updated} = ProductionLine.update_line(line.id, %{"active" => false}, @actor)
      assert updated.active == false
      assert audit_count("production_line.update") == 1
    end

    test "line_code 중복은 거부" do
      {:ok, _} = ProductionLine.create_line(%{line_code: "LINE-DUP", name: "X"}, @actor)
      assert {:error, %Ecto.Changeset{}} =
               ProductionLine.create_line(%{line_code: "LINE-DUP", name: "Y"}, @actor)
    end
  end

  describe "단계 CRUD + AuditLog" do
    setup do
      {:ok, line} = ProductionLine.create_line(%{line_code: "LINE-S", name: "S 라인"}, @actor)
      %{line_rec: line, p1: seed_process("SP1"), p2: seed_process("SP2"), eq: seed_equipment("SEQ1")}
    end

    test "생성/수정/삭제 + AuditLog 6 action", %{line_rec: line, p1: p1, p2: p2, eq: eq} do
      assert {:ok, step} =
               ProductionLine.create_step(
                 %{line_id: line.id, process_id: p1.id, equipment_id: eq.id, sequence: 1},
                 @actor
               )

      assert audit_count("production_line_step.create") == 1

      assert {:ok, _} = ProductionLine.update_step(step.id, %{"process_id" => p2.id}, @actor)
      assert audit_count("production_line_step.update") == 1

      assert {:ok, _} = ProductionLine.delete_step(step.id, @actor)
      assert audit_count("production_line_step.delete") == 1
      assert ProductionLine.get_step(step.id) == nil
    end

    test "라인 내 sequence 중복 거부", %{line_rec: line, p1: p1, p2: p2} do
      {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: p1.id, sequence: 1}, @actor)

      assert {:error, %Ecto.Changeset{}} =
               ProductionLine.create_step(%{line_id: line.id, process_id: p2.id, sequence: 1}, @actor)
    end

    test "reorder :down 으로 인접 단계 sequence swap", %{line_rec: line, p1: p1, p2: p2} do
      {:ok, s1} = ProductionLine.create_step(%{line_id: line.id, process_id: p1.id, sequence: 1}, @actor)
      {:ok, s2} = ProductionLine.create_step(%{line_id: line.id, process_id: p2.id, sequence: 2}, @actor)

      assert {:ok, _} = ProductionLine.reorder_step(s1.id, :down, @actor)

      assert ProductionLine.get_step(s1.id).sequence == 2
      assert ProductionLine.get_step(s2.id).sequence == 1
      # swap 은 step.update AuditLog 2건.
      assert audit_count("production_line_step.update") == 2
    end

    test "경계(첫 단계 :up)는 변경 없음", %{line_rec: line, p1: p1} do
      {:ok, s1} = ProductionLine.create_step(%{line_id: line.id, process_id: p1.id, sequence: 1}, @actor)
      assert {:ok, _} = ProductionLine.reorder_step(s1.id, :up, @actor)
      assert ProductionLine.get_step(s1.id).sequence == 1
    end
  end

  describe "steps_for_monitor (라인 모니터 입력 조립 — 정규식 제거)" do
    test "라인 단계를 sequence 순으로, 설비 라벨 LEFT JOIN, 미지정은 nil" do
      {:ok, line} = ProductionLine.create_line(%{line_code: "LINE-M", name: "M 라인"}, @actor)
      p1 = seed_process("MP1")
      p2 = seed_process("MP2")
      eq = seed_equipment("MEQ1")

      {:ok, _} =
        ProductionLine.create_step(%{line_id: line.id, process_id: p1.id, equipment_id: eq.id, sequence: 1}, @actor)

      # equipment_id 미지정 단계.
      {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: p2.id, sequence: 2}, @actor)

      steps = ProductionLine.steps_for_monitor("LINE-M")
      assert [s1, s2] = steps
      assert s1.process_code == "MP1"
      assert s1.equipment_name == "MEQ1"
      assert s1.equipment_active == true
      assert s2.process_code == "MP2"
      assert s2.equipment_id == nil
      assert s2.equipment_name == nil

      # :default 는 활성 라인 중 line_code 첫 라인.
      assert ProductionLine.steps_for_monitor(:default) != []
    end

    test "라인 0개/빈 라인이면 [] (안전)" do
      assert ProductionLine.steps_for_monitor(:default) == []
      {:ok, _} = ProductionLine.create_line(%{line_code: "LINE-E", name: "빈 라인"}, @actor)
      assert ProductionLine.steps_for_monitor("LINE-E") == []
    end
  end
end
