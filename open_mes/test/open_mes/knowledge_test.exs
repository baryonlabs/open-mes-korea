defmodule OpenMes.KnowledgeTest do
  @moduledoc """
  Knowledge 컨텍스트 + investigate RAG 연동 테스트 — 설계 27번 §4/§5.

  검증:
    - 문서 CRUD 시 AuditLog 동반(knowledge_document.create/update).
    - search_for_subject(태그 교집합, 만료/비활성 제외, 상한).
    - excerpt(토큰 방어 truncate).
    - investigate(mock) 컨텍스트에 knowledge 섹션 + referenced.knowledge 인용 URI.
    - AI 읽기 전용 — 조사로 문서 변경 0.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Ai.Investigation
  alias OpenMes.Audit.AuditLog
  alias OpenMes.Knowledge
  alias OpenMes.Knowledge.KnowledgeDocument
  alias OpenMes.MasterData
  alias OpenMes.Repo

  import Ecto.Query

  @actor "tester"
  @admin %{actor_id: @actor, role: "system_admin"}

  describe "CRUD + AuditLog" do
    test "create_document 는 AuditLog(create) 동반" do
      {:ok, doc} =
        Knowledge.create_document(
          %{"okf_type" => "표준작업서", "title" => "SOP", "uploaded_by" => @actor, "tags" => ["EQ-P03"]},
          @actor
        )

      logs =
        Repo.all(
          from a in AuditLog,
            where: a.resource_type == "knowledge_document" and a.resource_id == ^doc.id
        )

      assert [log] = logs
      assert log.action == "knowledge_document.create"
      assert log.actor_id == @actor
    end

    test "update_document 는 AuditLog(update) before/after 동반" do
      {:ok, doc} =
        Knowledge.create_document(%{"okf_type" => "검사기준", "uploaded_by" => @actor}, @actor)

      {:ok, _} = Knowledge.update_document(doc.id, %{"title" => "수정됨"}, @actor)

      log =
        Repo.one(
          from a in AuditLog,
            where: a.resource_type == "knowledge_document" and a.action == "knowledge_document.update",
            limit: 1
        )

      assert log.after["title"] == "수정됨"
    end

    test "okf_type 필수(없으면 changeset 에러)" do
      assert {:error, %Ecto.Changeset{}} =
               Knowledge.create_document(%{"title" => "no type", "uploaded_by" => @actor}, @actor)
    end
  end

  describe "search_for_subject / excerpt" do
    setup do
      {:ok, manual} =
        Knowledge.create_document(
          %{"okf_type" => "설비매뉴얼", "title" => "EQ-P03 매뉴얼", "uploaded_by" => @actor, "tags" => ["EQ-P03"], "body" => String.duplicate("가", 1000)},
          @actor
        )

      {:ok, _expired} =
        Knowledge.create_document(
          %{"okf_type" => "트러블슈팅", "title" => "만료문서", "uploaded_by" => @actor, "tags" => ["EQ-P03"], "valid_until" => ~D[2000-01-01]},
          @actor
        )

      {:ok, _inactive} =
        Knowledge.create_document(
          %{"okf_type" => "트러블슈팅", "title" => "비활성", "uploaded_by" => @actor, "tags" => ["EQ-P03"], "active" => false},
          @actor
        )

      %{manual: manual}
    end

    test "태그 매칭 + 만료/비활성 제외", %{manual: manual} do
      docs = Knowledge.search_for_subject(%{equipment_code: "EQ-P03", process_codes: []})
      titles = Enum.map(docs, & &1.title)
      assert manual.title in titles
      refute "만료문서" in titles
      refute "비활성" in titles
    end

    test "매칭 키 없으면 빈 결과" do
      assert Knowledge.search_for_subject(%{equipment_code: nil, process_codes: []}) == []
    end

    test "excerpt 는 max_chars 로 truncate" do
      assert String.length(Knowledge.excerpt(String.duplicate("x", 1000), 600)) <= 620
      assert Knowledge.excerpt(String.duplicate("x", 1000), 600) =~ "생략"
      assert Knowledge.excerpt("짧음", 600) == "짧음"
    end
  end

  describe "investigate RAG 연동(mock)" do
    setup do
      {:ok, equipment} =
        MasterData.create_equipment(%{equipment_code: "EQ-P03", name: "사출기"}, @actor)

      {:ok, _doc} =
        Knowledge.create_document(
          %{"okf_type" => "트러블슈팅", "title" => "진동 트러블슈팅", "resource" => "mes://knowledge/troubleshooting/eq-p03", "uploaded_by" => @actor, "tags" => ["EQ-P03"], "body" => "진동 원인 분석"},
          @actor
        )

      %{equipment: equipment}
    end

    test "build_context 에 knowledge 섹션 + 인용 URI 포함" do
      {:ok, context} = Investigation.build_context("EQ-P03", [], @admin)

      assert %{documents: docs, total: total} = context.knowledge
      assert total >= 1
      assert Enum.any?(docs, &(&1.resource == "mes://knowledge/troubleshooting/eq-p03"))
      assert "mes://knowledge/troubleshooting/eq-p03" in context.referenced.knowledge
      assert "knowledge_documents" in context.referenced.sources
    end

    test "investigate(mock) 분석에 지식 문서 반영 + 조사로 문서 변경 0" do
      before_count = Repo.aggregate(KnowledgeDocument, :count, :id)

      {:ok, %{result: result, context: context}} =
        Investigation.investigate("EQ-P03", "진동 이상 원인은?", @admin)

      assert result.analysis =~ "진동 트러블슈팅"
      assert Enum.any?(result.findings, &(Map.get(&1, :kind) == "knowledge"))
      # 인용 URI 가 AiInteraction referenced 에 기록(감사).
      assert context.referenced.knowledge != []
      # AI 읽기 전용 — 문서 개수 불변.
      assert Repo.aggregate(KnowledgeDocument, :count, :id) == before_count
    end
  end
end
