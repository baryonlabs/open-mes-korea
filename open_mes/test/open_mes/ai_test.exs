defmodule OpenMes.AiTest do
  @moduledoc """
  AI 자연어 라인 구성 컨텍스트 테스트 — 설계 23번 §A.

  검증: propose(mock, step 쓰기 0) → approve → apply(executed, step AuditLog) /
  미승인 apply 차단 / 거부 / 화이트리스트 외 process 차단 / ai_context 인가 / 상태머신.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Ai
  alias OpenMes.Ai.{AiInteraction, MockProvider, SkillRegistry}
  alias OpenMes.{MasterData, ProductionLine}
  alias OpenMes.Audit.AuditLog
  alias OpenMes.Outbox.Event
  alias OpenMes.Repo

  import Ecto.Query

  @actor "tester"
  @reviewer "reviewer"

  defp seed_process(code, name), do: elem(MasterData.create_process(%{process_code: code, name: name}, @actor), 1)

  defp audit_count(action),
    do: Repo.one(from a in AuditLog, where: a.action == ^action, select: count(a.id))

  defp event_count(type),
    do: Repo.one(from e in Event, where: e.event_type == ^type, select: count(e.id))

  setup do
    {:ok, line} = ProductionLine.create_line(%{line_code: "LINE-AI", name: "AI 라인"}, @actor)
    dry = seed_process("P-DRY", "건조")
    preheat = seed_process("P-PREHEAT", "예열")
    pack = seed_process("P-PACK", "포장")

    {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: dry.id, sequence: 1}, @actor)
    {:ok, _} = ProductionLine.create_step(%{line_id: line.id, process_id: pack.id, sequence: 2}, @actor)

    %{line_rec: line, dry: dry, preheat: preheat, pack: pack}
  end

  describe "AiInteraction 상태머신" do
    test "허용 전이만 통과" do
      assert AiInteraction.allowed_transition?("proposed", "approved")
      assert AiInteraction.allowed_transition?("proposed", "rejected")
      assert AiInteraction.allowed_transition?("approved", "executed")
      assert AiInteraction.allowed_transition?("approved", "failed")
      refute AiInteraction.allowed_transition?("proposed", "executed")
      refute AiInteraction.allowed_transition?("rejected", "approved")
      refute AiInteraction.allowed_transition?("executed", "approved")
    end
  end

  describe "ProductionLine.ai_context/2 인가 + 읽기전용" do
    test "권한자(production_manager)는 컨텍스트 반환", %{line_rec: line} do
      assert {:ok, ctx} = ProductionLine.ai_context(line.id, "production_manager")
      assert ctx.line.line_code == "LINE-AI"
      assert length(ctx.current_steps) == 2
      assert Enum.any?(ctx.available_processes, &(&1.process_code == "P-PREHEAT"))
    end

    test "권한 없는 role 은 :unauthorized", %{line_rec: line} do
      assert {:error, :unauthorized} = ProductionLine.ai_context(line.id, "operator")
    end
  end

  describe "MockProvider 규칙 파서" do
    test "한국어 추가/순서변경 지시 → diff op", %{line_rec: line} do
      {:ok, ctx} = ProductionLine.ai_context(line.id, "system_admin")

      assert {:ok, result} =
               MockProvider.propose_line_diff(ctx, "건조 다음에 예열 공정 추가, 포장을 마지막으로")

      assert Enum.any?(result.diff, &(&1["op"] == "add_step" and &1["process_code"] == "P-PREHEAT"))
      assert Enum.any?(result.diff, &(&1["op"] == "reorder" and &1["process_code"] == "P-PACK"))
      assert result.referenced.available_process_count == 3
    end

    test "화이트리스트 외 공정명은 diff 제외 + 경고", %{line_rec: line} do
      {:ok, ctx} = ProductionLine.ai_context(line.id, "system_admin")
      assert {:ok, result} = MockProvider.propose_line_diff(ctx, "없는공정XYZ 추가")
      assert result.diff == []
      assert result.summary =~ "찾"
    end
  end

  describe "propose → approve → apply 전 흐름" do
    test "propose 는 AiInteraction 만 만들고 step 쓰기 0", %{line_rec: line} do
      before_steps = length(ProductionLine.list_steps(line.id))

      assert {:ok, interaction} =
               Ai.propose_line_config(line.id, "건조 다음에 예열 공정 추가", %{actor_id: @actor, role: "system_admin"})

      assert interaction.approval_status == "proposed"
      assert interaction.provider == "mock"
      # step 쓰기 0 — 라인 단계 수 불변
      assert length(ProductionLine.list_steps(line.id)) == before_steps
      assert audit_count("ai_interaction.propose") == 1
      assert event_count("ai_action.proposed") == 1
    end

    test "승인 후 apply 하면 step 반영 + executed + step AuditLog", %{line_rec: line} do
      {:ok, interaction} =
        Ai.propose_line_config(line.id, "건조 다음에 예열 공정 추가", %{actor_id: @actor, role: "system_admin"})

      assert {:ok, approved} = Ai.approve_proposal(interaction.id, @reviewer)
      assert approved.approval_status == "approved"
      assert approved.reviewer_id == @reviewer
      assert audit_count("ai_interaction.approve") == 1
      assert event_count("ai_action.approved") == 1

      assert {:ok, executed} = Ai.apply_proposal(interaction.id, @reviewer)
      assert executed.approval_status == "executed"

      # 예열 step 이 실제로 추가됨(건조 다음 = sequence 2 위치).
      steps = ProductionLine.list_steps(line.id)
      assert length(steps) == 3
      process_codes = Enum.map(steps, fn s -> MasterData.get_process(s.process_id).process_code end)
      assert "P-PREHEAT" in process_codes
      # 건조(P-DRY) 다음에 예열이 옴
      assert Enum.find_index(process_codes, &(&1 == "P-PREHEAT")) ==
               Enum.find_index(process_codes, &(&1 == "P-DRY")) + 1

      assert audit_count("ai_interaction.execute") == 1
      assert audit_count("production_line_step.create") >= 1
    end

    test "미승인(proposed) 상태 apply 는 차단", %{line_rec: line} do
      {:ok, interaction} =
        Ai.propose_line_config(line.id, "건조 다음에 예열 공정 추가", %{actor_id: @actor, role: "system_admin"})

      assert {:error, :not_approved} = Ai.apply_proposal(interaction.id, @reviewer)
      # 차단되어 step 변경 없음
      assert length(ProductionLine.list_steps(line.id)) == 2
    end

    test "거부 → rejected, 이후 승인/적용 불가", %{line_rec: line} do
      {:ok, interaction} =
        Ai.propose_line_config(line.id, "건조 다음에 예열 공정 추가", %{actor_id: @actor, role: "system_admin"})

      assert {:ok, rejected} = Ai.reject_proposal(interaction.id, "불필요", @reviewer)
      assert rejected.approval_status == "rejected"
      assert audit_count("ai_interaction.reject") == 1

      # 터미널 — 승인 전이 차단
      assert {:error, %Ecto.Changeset{}} = Ai.approve_proposal(interaction.id, @reviewer)
    end

    test "삭제 지시도 apply 되면 step 제거", %{line_rec: line} do
      {:ok, interaction} =
        Ai.propose_line_config(line.id, "포장 삭제", %{actor_id: @actor, role: "system_admin"})

      {:ok, _} = Ai.approve_proposal(interaction.id, @reviewer)
      assert {:ok, _} = Ai.apply_proposal(interaction.id, @reviewer)

      steps = ProductionLine.list_steps(line.id)
      codes = Enum.map(steps, fn s -> MasterData.get_process(s.process_id).process_code end)
      refute "P-PACK" in codes
      assert audit_count("production_line_step.delete") >= 1
    end
  end

  describe "화이트리스트 / 권한" do
    test "SkillRegistry 는 propose_line_config 만 허용" do
      assert SkillRegistry.allowed?("propose_line_config")
      refute SkillRegistry.allowed?("delete_everything")
    end

    test "권한 없는 role 의 propose 는 :unauthorized", %{line_rec: line} do
      assert {:error, :unauthorized} =
               Ai.propose_line_config(line.id, "건조 다음에 예열 추가", %{actor_id: @actor, role: "operator"})
    end
  end
end
