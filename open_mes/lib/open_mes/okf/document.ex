defmodule OpenMes.Okf.Document do
  @moduledoc """
  OKF 개념 문서 1건 변환 — 설계 27번 §2.2. 순수 함수.

  parse: OKF 마크다운 → KnowledgeDocument attrs(+경고). **절대 reject 안 함**(관용적):
    - `type`(okf_type) 없으면 "미분류" 기본값 + 경고.
    - 권장 필드(type/title/description/resource/tags/version/valid_until)는 컬럼에 매핑.
    - 나머지 미지 프론트매터 필드는 `extra` 에 보존(round-trip).

  generate: KnowledgeDocument → OKF 마크다운 텍스트(프론트매터 + 본문).
  """
  alias OpenMes.Knowledge.KnowledgeDocument
  alias OpenMes.Okf.Frontmatter

  # 컬럼으로 직접 매핑하는 프론트매터 키(이외는 extra 보존). type→okf_type, timestamp 는 메타.
  @mapped_keys ~w(type title description resource tags version valid_until timestamp okf_version)

  @default_type "미분류"

  @doc """
  OKF 마크다운 텍스트 → {attrs(map), warnings(list)}.

  `default_uploaded_by` 는 프론트매터에 작성자 정보가 없을 때의 uploaded_by 기본값.
  """
  def parse(text, default_uploaded_by) when is_binary(text) do
    {fm, body, fm_warnings} = Frontmatter.parse(text)

    {okf_type, type_warnings} =
      case Map.get(fm, "type") do
        t when is_binary(t) and t != "" -> {t, []}
        _ -> {@default_type, ["type 필드가 없어 '#{@default_type}'로 처리합니다"]}
      end

    extra = Map.drop(fm, @mapped_keys)

    attrs = %{
      "okf_type" => okf_type,
      "title" => Map.get(fm, "title"),
      "description" => Map.get(fm, "description"),
      "resource" => Map.get(fm, "resource"),
      "tags" => normalize_tags(Map.get(fm, "tags")),
      "body" => body,
      "extra" => extra,
      "version" => Map.get(fm, "version"),
      "valid_until" => parse_date(Map.get(fm, "valid_until")),
      "uploaded_by" => default_uploaded_by
    }

    {attrs, fm_warnings ++ type_warnings}
  end

  @doc "KnowledgeDocument → OKF 마크다운 텍스트(.md)."
  def generate(%KnowledgeDocument{} = doc) do
    fm =
      %{
        "type" => doc.okf_type,
        "title" => doc.title,
        "description" => doc.description,
        "resource" => doc.resource || canonical_resource(doc),
        "tags" => doc.tags || [],
        "version" => doc.version,
        "valid_until" => date_to_iso(doc.valid_until),
        "timestamp" => timestamp_iso(doc)
      }
      |> drop_nil()
      # 미지 필드(extra)를 병합 — 매핑 필드가 우선(round-trip 보존).
      |> then(fn base -> Map.merge(normalize_extra(doc.extra), base) end)

    Frontmatter.generate(fm) <> "\n" <> (doc.body || "")
  end

  @doc "정규 OKF resource URI 생성(resource 없을 때 — `mes://knowledge/{type}/{id}`)."
  def canonical_resource(%KnowledgeDocument{okf_type: type, id: id}) do
    "mes://knowledge/#{slug(type)}/#{id || "new"}"
  end

  @doc "title 또는 id 기반 파일명 슬러그(번들 파일명용)."
  def slug(nil), do: "untitled"

  def slug(str) when is_binary(str) do
    str
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "untitled"
      s -> s
    end
  end

  # ── 내부 ────────────────────────────────────────────────────────────

  defp normalize_tags(tags) when is_list(tags), do: tags
  defp normalize_tags(nil), do: []
  defp normalize_tags(other) when is_binary(other), do: [other]
  defp normalize_tags(_), do: []

  defp normalize_extra(extra) when is_map(extra), do: extra
  defp normalize_extra(_), do: %{}

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp date_to_iso(%Date{} = d), do: Date.to_iso8601(d)
  defp date_to_iso(_), do: nil

  defp timestamp_iso(%KnowledgeDocument{updated_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp timestamp_iso(_), do: nil

  defp drop_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
