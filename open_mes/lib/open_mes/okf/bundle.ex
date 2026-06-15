defmodule OpenMes.Okf.Bundle do
  @moduledoc """
  OKF 번들(디렉토리) import/export — 설계 27번 §2.3. 순수 함수(파일 I/O·zip 은 호출측).

  export: KnowledgeDocument 목록 → 파일맵(`경로 => 내용`):
    - `index.md`            루트 색인(`okf_version: "0.1"` 프론트매터 + 문서 목록).
    - `{okf_type}/{slug}.md` 각 문서(Document.generate).
    - `{okf_type}/index.md`  type 별 색인(예약 파일).
    - `log.md`               AuditLog → 변경 이력(예약 파일).

  import_bundle: 파일맵 → [{attrs, warnings}]. **관용적**: index/log 없어도 진행,
  okf_version 없어도 진행, 예약 파일은 건너뜀, 나머지 *.md 는 Document.parse.
  """
  alias OpenMes.Okf.{Document, Frontmatter}

  @okf_version "0.1"
  @reserved ~w(index.md log.md)

  @doc """
  KnowledgeDocument 목록 → OKF 번들 파일맵.

  `audit_logs_by_doc` 는 `%{doc_id => [audit_log]}`(log.md 생성용, 없으면 빈 맵).
  """
  def export(documents, audit_logs_by_doc \\ %{}) when is_list(documents) do
    doc_files =
      Map.new(documents, fn doc ->
        {doc_path(doc), Document.generate(doc)}
      end)

    type_indexes =
      documents
      |> Enum.group_by(& &1.okf_type)
      |> Map.new(fn {type, docs} ->
        {"#{Document.slug(type)}/index.md", type_index(type, docs)}
      end)

    doc_files
    |> Map.merge(type_indexes)
    |> Map.put("index.md", root_index(documents))
    |> Map.put("log.md", log_md(documents, audit_logs_by_doc))
  end

  @doc """
  번들 파일맵 → [{attrs, warnings}]. 예약 파일 제외, 나머지 *.md 를 Document.parse.

  누락 index/log 허용, okf_version 미지/없음 허용(관용적).
  """
  def import_bundle(file_map, default_uploaded_by) when is_map(file_map) do
    file_map
    |> Enum.reject(fn {path, _content} -> reserved?(path) end)
    |> Enum.filter(fn {path, _content} -> String.ends_with?(path, ".md") end)
    |> Enum.map(fn {_path, content} -> Document.parse(content, default_uploaded_by) end)
  end

  # ── 파일 경로/색인 ──────────────────────────────────────────────────

  defp doc_path(doc) do
    slug = Document.slug(doc.title || doc.id)
    "#{Document.slug(doc.okf_type)}/#{slug}.md"
  end

  defp root_index(documents) do
    fm =
      Frontmatter.generate(%{
        "okf_version" => @okf_version,
        "title" => "Open MES Korea 지식베이스",
        "type" => "색인"
      })

    body =
      "# Open MES Korea 지식베이스\n\n" <>
        "총 #{length(documents)}건의 OKF 문서.\n\n" <>
        Enum.map_join(documents, "\n", fn d ->
          "- [#{d.title || d.okf_type}](#{doc_path(d)}) — #{d.okf_type}"
        end) <> "\n"

    fm <> "\n" <> body
  end

  defp type_index(type, docs) do
    fm = Frontmatter.generate(%{"type" => "색인", "title" => "#{type} 색인"})

    body =
      "# #{type}\n\n" <>
        Enum.map_join(docs, "\n", fn d ->
          slug = Document.slug(d.title || d.id)
          "- [#{d.title || d.id}](#{slug}.md)"
        end) <> "\n"

    fm <> "\n" <> body
  end

  defp log_md(documents, audit_logs_by_doc) do
    fm = Frontmatter.generate(%{"type" => "변경이력", "title" => "변경 이력(log)"})

    entries =
      documents
      |> Enum.flat_map(fn doc ->
        logs = Map.get(audit_logs_by_doc, doc.id, [])

        case logs do
          [] ->
            ["- #{doc.title || doc.id} (#{doc.okf_type}) — 등록 by #{doc.uploaded_by}"]

          logs ->
            Enum.map(logs, fn log ->
              ts = log_ts(log)
              "- #{ts} · #{log.action} · #{doc.title || doc.id} by #{log.actor_id}"
            end)
        end
      end)

    fm <> "\n# 변경 이력\n\n" <> Enum.join(entries, "\n") <> "\n"
  end

  defp log_ts(%{inserted_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp log_ts(%{inserted_at: ts}) when not is_nil(ts), do: to_string(ts)
  defp log_ts(_), do: ""

  defp reserved?(path), do: Path.basename(path) in @reserved
end
