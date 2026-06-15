defmodule OpenMesWeb.KnowledgeExportController do
  @moduledoc """
  OKF 지식베이스 내보내기 컨트롤러(읽기 전용) — 설계 27번 §3.1.

  - `export/2`(전체): 모든 문서를 OKF 번들(디렉토리 구조)로 만들어 `:zip`(Erlang 기본,
    외부 dep 0)으로 패킹해 다운로드한다. index.md/log.md/{type}/{slug}.md 포함.
  - `export_one/2`(단건): 문서 1건을 OKF 마크다운(.md)으로 다운로드한다.

  순수 변환(Bundle/Document)은 읽기만 — AuditLog 무관.
  """
  use OpenMesWeb, :controller

  alias OpenMes.Knowledge
  alias OpenMes.Okf.{Bundle, Document}

  @doc "전체 문서 → OKF 번들 zip 다운로드."
  def export(conn, _params) do
    documents = Knowledge.list_documents(%{})
    audit_logs = audit_logs_by_doc(documents)
    file_map = Bundle.export(documents, audit_logs)

    # :zip.create 는 [{charlist 경로, 바이너리}] 와 [:memory] 옵션으로 인메모리 zip 생성.
    entries = Enum.map(file_map, fn {path, content} -> {String.to_charlist(path), content} end)
    {:ok, {_name, zip_binary}} = :zip.create(~c"okf_knowledge_bundle.zip", entries, [:memory])

    conn
    |> put_resp_content_type("application/zip")
    |> send_download({:binary, zip_binary}, filename: "okf_knowledge_bundle.zip")
  end

  @doc "단건 문서 → OKF 마크다운(.md) 다운로드."
  def export_one(conn, %{"id" => id}) do
    case Knowledge.fetch_document(id) do
      {:ok, doc} ->
        filename = "#{Document.slug(doc.title || doc.okf_type)}.md"

        conn
        |> put_resp_content_type("text/markdown")
        |> send_download({:binary, Document.generate(doc)}, filename: filename, charset: "utf-8")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> text("존재하지 않는 문서입니다.")
    end
  end

  defp audit_logs_by_doc(documents) do
    Map.new(documents, fn doc -> {doc.id, Knowledge.document_audit_logs(doc.id)} end)
  end
end
