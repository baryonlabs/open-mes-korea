defmodule OpenMes.Knowledge do
  @moduledoc """
  지식베이스(Knowledge) 바운디드 컨텍스트 — 설계 27번. **생산 데이터와 분리된 RAG 문서 영역.**

  OKF 개념 문서를 사람이 CRUD 하고(AuditLog 필수), AI 조사(investigate)가 설비/공정
  연관 문서를 **읽기 전용**으로 검색·발췌·인용한다.

  핵심 불변식(MasterData 동형):
    - 모든 쓰기(create/update/import)는 단일 `Ecto.Multi` 안에서 AuditLog 1건을 동반한다
      (= OKF `log.md` 대응). resource_type = "knowledge_document".
    - 모든 쓰기 함수는 actor_id 를 명시적으로 받는다.
    - 삭제 없음(이력 보존) — 비활성화는 active=false 수정.
    - 검색/발췌(search_for_subject/excerpt)는 읽기 전용(AuditLog 무관). AI 에는 plain map 만.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit
  alias OpenMes.Audit.AuditLog
  alias OpenMes.Knowledge.KnowledgeDocument
  alias OpenMes.Repo

  @resource_type "knowledge_document"
  @search_limit 5
  @excerpt_chars 600

  # ──────────────────────────────────────────────────────────────────
  # 조회 (읽기 — AuditLog 불필요)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  문서 목록. 필터(모두 선택):
    - "okf_type": 유형 정확히 일치
    - "tag": 단일 태그 부분 일치(tags 중 하나라도 포함)
    - "active": true/false
  """
  def list_documents(filters \\ %{}) do
    KnowledgeDocument
    |> filter_okf_type(filters)
    |> filter_tag(filters)
    |> filter_active(filters)
    |> order_recent()
    |> Repo.all()
  end

  def get_document(id), do: Repo.get(KnowledgeDocument, id)

  def fetch_document(id) do
    case Repo.get(KnowledgeDocument, id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  def get_document_by_resource(resource) when is_binary(resource),
    do: Repo.get_by(KnowledgeDocument, resource: resource)

  @doc "등록된 distinct okf_type 목록(필터 셀렉트용)."
  def list_okf_types do
    from(d in KnowledgeDocument, distinct: true, select: d.okf_type, order_by: d.okf_type)
    |> Repo.all()
  end

  @doc "폼용 changeset(쓰기 아님)."
  def change_document(%KnowledgeDocument{} = doc, attrs \\ %{}),
    do: KnowledgeDocument.changeset(doc, attrs)

  @doc "해당 문서의 변경 이력(AuditLog — 상세 화면). 최근순."
  def document_audit_logs(id) do
    from(a in AuditLog,
      where: a.resource_type == ^@resource_type and a.resource_id == ^id,
      order_by: [desc: a.inserted_at]
    )
    |> Repo.all()
  end

  # ──────────────────────────────────────────────────────────────────
  # 생성 / 수정 (AuditLog 동반 — 단일 Multi)
  # ──────────────────────────────────────────────────────────────────

  @doc "문서 생성(AuditLog: knowledge_document.create)."
  def create_document(attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:record, KnowledgeDocument.changeset(%KnowledgeDocument{}, attrs))
    |> Audit.put_log(:audit, fn %{record: record} ->
      %{
        actor_id: actor_id,
        action: "#{@resource_type}.create",
        resource_type: @resource_type,
        resource_id: record.id,
        before: nil,
        after: snapshot(record)
      }
    end)
    |> Repo.transaction()
    |> normalize_result()
  end

  @doc "문서 수정(AuditLog: knowledge_document.update). 비활성화도 이 경로(active=false)."
  def update_document(id, attrs, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load(repo, id) end)
    |> Multi.update(:record, fn %{load: doc} -> KnowledgeDocument.changeset(doc, attrs) end)
    |> Audit.put_log(:audit, fn %{load: before_rec, record: after_rec} ->
      %{
        actor_id: actor_id,
        action: "#{@resource_type}.update",
        resource_type: @resource_type,
        resource_id: after_rec.id,
        before: snapshot(before_rec),
        after: snapshot(after_rec)
      }
    end)
    |> Repo.transaction()
    |> normalize_result()
  end

  @doc """
  OKF 번들 import — attrs 목록(`Okf.Bundle.import_bundle` 산출)을 각각 upsert.

  resource 가 있으면 기존 문서 update, 없으면 create(관용적 — reject 0). 각 문서마다
  AuditLog 동반(개별 트랜잭션). 반환: %{imported: n, errors: [...], warnings: [...]}.
  """
  def import_documents(attrs_with_warnings, actor_id) when is_list(attrs_with_warnings) do
    Enum.reduce(attrs_with_warnings, %{imported: 0, errors: [], warnings: []}, fn
      {attrs, warnings}, acc ->
        result = upsert_by_resource(attrs, actor_id)

        case result do
          {:ok, _doc} ->
            %{acc | imported: acc.imported + 1, warnings: acc.warnings ++ warnings}

          {:error, reason} ->
            label = Map.get(attrs, "title") || Map.get(attrs, "okf_type") || "문서"
            %{acc | errors: acc.errors ++ ["#{label}: #{inspect_error(reason)}"], warnings: acc.warnings ++ warnings}
        end
    end)
  end

  defp upsert_by_resource(attrs, actor_id) do
    case Map.get(attrs, "resource") do
      resource when is_binary(resource) and resource != "" ->
        case get_document_by_resource(resource) do
          nil -> create_document(attrs, actor_id)
          existing -> update_document(existing.id, attrs, actor_id)
        end

      _ ->
        create_document(attrs, actor_id)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 검색 / 발췌 (읽기 전용 — AI 조사 RAG. AuditLog 무관)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  설비/공정 기준 관련 OKF 문서 검색(읽기 전용) — 설계 27번 §4.1.

  subject: %{equipment_code: code, process_codes: [..]}. tags 가 {code | codes} 중
  하나라도 포함하는 active 문서(만료 제외)를 태그 매칭 수·최근순으로 상한 N건.
  """
  def search_for_subject(subject, limit \\ @search_limit) do
    keys =
      [Map.get(subject, :equipment_code) | List.wrap(Map.get(subject, :process_codes, []))]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    case keys do
      [] ->
        []

      keys ->
        today = Date.utc_today()

        from(d in KnowledgeDocument,
          where: d.active == true,
          where: is_nil(d.valid_until) or d.valid_until >= ^today,
          where: fragment("? && ?", d.tags, ^keys),
          order_by: [desc: d.updated_at],
          limit: ^limit
        )
        |> Repo.all()
        # 태그 매칭 수 우선 정렬(순수 — DB 정렬은 최근순, 매칭수는 인메모리 상한 N건 내).
        |> Enum.sort_by(fn d -> -length(matching_tags(d.tags, keys)) end)
    end
  end

  @doc "마크다운 본문 → 앞부분 발췌(최대 max_chars). raw 전량 금지(토큰 방어)."
  def excerpt(body, max_chars \\ @excerpt_chars)
  def excerpt(nil, _max_chars), do: ""

  def excerpt(body, max_chars) when is_binary(body) do
    trimmed = String.trim(body)

    if String.length(trimmed) <= max_chars do
      trimmed
    else
      String.slice(trimmed, 0, max_chars) <> "…(이하 생략)"
    end
  end

  defp matching_tags(tags, keys) when is_list(tags), do: Enum.filter(tags, &(&1 in keys))
  defp matching_tags(_, _), do: []

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp filter_okf_type(query, %{"okf_type" => t}) when is_binary(t) and t != "",
    do: from(d in query, where: d.okf_type == ^t)

  defp filter_okf_type(query, _), do: query

  defp filter_tag(query, %{"tag" => tag}) when is_binary(tag) and tag != "",
    do: from(d in query, where: fragment("? && ?", d.tags, ^[tag]))

  defp filter_tag(query, _), do: query

  defp filter_active(query, %{"active" => v}) when v in [true, "true"],
    do: from(d in query, where: d.active == true)

  defp filter_active(query, %{"active" => v}) when v in [false, "false"],
    do: from(d in query, where: d.active == false)

  defp filter_active(query, _), do: query

  defp order_recent(query), do: from(d in query, order_by: [desc: d.updated_at])

  defp load(repo, id) do
    case repo.get(KnowledgeDocument, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp normalize_result({:ok, %{record: record}}), do: {:ok, record}
  defp normalize_result({:error, :load, :not_found, _}), do: {:error, :not_found}
  defp normalize_result({:error, _step, %Ecto.Changeset{} = cs, _}), do: {:error, cs}
  defp normalize_result({:error, _step, reason, _}), do: {:error, reason}

  defp inspect_error(%Ecto.Changeset{} = cs) do
    cs.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp inspect_error(reason), do: inspect(reason)

  # 감사 스냅샷: 메타 필드 제외한 도메인 필드만.
  defp snapshot(%KnowledgeDocument{} = record) do
    KnowledgeDocument.__schema__(:fields)
    |> Enum.reject(&(&1 in [:id, :inserted_at, :updated_at]))
    |> Map.new(fn field -> {field, serialize(Map.get(record, field))} end)
  end

  defp serialize(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize(other), do: other
end
