defmodule OpenMes.OkfTest do
  @moduledoc """
  OKF 순수 함수 파서/생성기 테스트 — 설계 27번 §2.

  검증:
    - Frontmatter parse/generate round-trip(미지 필드 보존).
    - Document parse↔generate round-trip(컬럼 매핑 + extra 보존).
    - 관용적 소비: type 누락 경고(거부 X), 프론트매터 없음(전체 본문), 깨진 입력 비-reject.
    - Bundle export(index.md/log.md/okf_version) + import(누락 index 허용).
  """
  use ExUnit.Case, async: true

  alias OpenMes.Knowledge.KnowledgeDocument
  alias OpenMes.Okf.{Bundle, Document, Frontmatter}

  describe "Frontmatter.parse/1 — 관용적" do
    test "표준 프론트매터 + tags 인라인/블록" do
      text = """
      ---
      type: 설비매뉴얼
      title: EQ-P03 매뉴얼
      tags: [EQ-P03, 사출기]
      ---
      # 본문
      내용
      """

      {fm, body, warnings} = Frontmatter.parse(text)
      assert fm["type"] == "설비매뉴얼"
      assert fm["title"] == "EQ-P03 매뉴얼"
      assert fm["tags"] == ["EQ-P03", "사출기"]
      assert body =~ "# 본문"
      assert warnings == []
    end

    test "tags 들여쓴 블록(- item)" do
      text = "---\ntype: x\ntags:\n  - A\n  - B\n---\nbody"
      {fm, _body, _w} = Frontmatter.parse(text)
      assert fm["tags"] == ["A", "B"]
    end

    test "프론트매터 구분자 없으면 전체를 본문으로(거부 X)" do
      {fm, body, warnings} = Frontmatter.parse("구분자 없는 그냥 마크다운")
      assert fm == %{}
      assert body == "구분자 없는 그냥 마크다운"
      assert warnings != []
    end

    test "미지 필드 보존" do
      {fm, _body, _w} = Frontmatter.parse("---\ntype: x\nmystery_field: keepme\n---\nb")
      assert fm["mystery_field"] == "keepme"
    end

    test "generate round-trip(미지 필드 보존)" do
      original = %{"type" => "트러블슈팅", "title" => "제목", "mystery" => "보존값", "tags" => ["EQ-P03"]}
      generated = Frontmatter.generate(original)
      {parsed, _body, _w} = Frontmatter.parse(generated <> "\n본문")
      assert parsed["type"] == "트러블슈팅"
      assert parsed["mystery"] == "보존값"
      assert parsed["tags"] == ["EQ-P03"]
    end
  end

  describe "Document.parse/2 — 관용적 소비" do
    test "type 누락 시 '미분류' + 경고(거부 X)" do
      {attrs, warnings} = Document.parse("---\ntitle: 무유형\n---\n본문", "tester")
      assert attrs["okf_type"] == "미분류"
      assert Enum.any?(warnings, &(&1 =~ "type"))
    end

    test "미지 프론트매터 필드는 extra 에 보존" do
      {attrs, _w} = Document.parse("---\ntype: x\nunknown_key: val\n---\nbody", "tester")
      assert attrs["extra"]["unknown_key"] == "val"
    end

    test "깨진 입력도 reject 하지 않음" do
      {attrs, _w} = Document.parse("완전히 깨진 입력 :::: ---", "tester")
      assert attrs["okf_type"] == "미분류"
      assert attrs["uploaded_by"] == "tester"
    end
  end

  describe "Document.generate/1 round-trip" do
    test "컬럼 매핑 + extra 보존" do
      doc = %KnowledgeDocument{
        id: "00000000-0000-0000-0000-000000000001",
        okf_type: "표준작업서",
        title: "사출 SOP",
        description: "요약",
        resource: "mes://knowledge/sop/x",
        tags: ["P-INJECTION", "사출"],
        body: "# 본문\n내용",
        extra: %{"custom" => "보존"},
        version: "1.0"
      }

      md = Document.generate(doc)
      {attrs, _warnings} = Document.parse(md, "tester")

      assert attrs["okf_type"] == "표준작업서"
      assert attrs["title"] == "사출 SOP"
      assert attrs["resource"] == "mes://knowledge/sop/x"
      assert attrs["tags"] == ["P-INJECTION", "사출"]
      assert attrs["extra"]["custom"] == "보존"
      assert attrs["body"] =~ "# 본문"
    end

    test "resource 없으면 canonical URI 자동 생성" do
      doc = %KnowledgeDocument{id: "abc", okf_type: "트러블슈팅", title: "t", tags: [], body: ""}
      md = Document.generate(doc)
      assert md =~ "mes://knowledge/"
    end
  end

  describe "Bundle export/import" do
    test "export 는 index.md/log.md/okf_version 포함" do
      docs = [
        %KnowledgeDocument{id: "1", okf_type: "설비매뉴얼", title: "EQ-P03", tags: ["EQ-P03"], body: "x", uploaded_by: "system"}
      ]

      file_map = Bundle.export(docs, %{})
      assert Map.has_key?(file_map, "index.md")
      assert Map.has_key?(file_map, "log.md")
      assert file_map["index.md"] =~ "okf_version"
      assert file_map["index.md"] =~ "0.1"
    end

    test "import 는 누락 index/log 허용(관용적), 예약 파일 제외" do
      file_map = %{
        "설비매뉴얼/eq-p03.md" => "---\ntype: 설비매뉴얼\ntitle: EQ-P03\ntags: [EQ-P03]\n---\n본문",
        "index.md" => "index 파일(제외 대상)"
      }

      results = Bundle.import_bundle(file_map, "importer")
      assert length(results) == 1
      {attrs, _w} = hd(results)
      assert attrs["okf_type"] == "설비매뉴얼"
      assert attrs["tags"] == ["EQ-P03"]
    end
  end
end
