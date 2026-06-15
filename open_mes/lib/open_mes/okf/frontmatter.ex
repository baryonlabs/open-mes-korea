defmodule OpenMes.Okf.Frontmatter do
  @moduledoc """
  경량 YAML 프론트매터 파서/생성기 — 설계 27번 §2.1. **외부 dep 0**(순수 함수).

  지원 범위(의도적 최소, 중첩 없음):
    - `---\\n...\\n---\\n본문` 분리.
    - `key: value` 스칼라(문자열/숫자/불리언/날짜는 문자열로 보존).
    - `tags:` 인라인 리스트(`[a, b]`) 또는 들여쓴 블록(`- item`).
    - 미지 키 전부 보존(관용적 소비).

  관용적 원칙: parse 는 절대 reject 하지 않는다. 구분자 없으면 frontmatter %{},
  body 전체. 파싱 불가 줄은 무시하고 경고를 누적한다.
  """

  @doc """
  마크다운 텍스트 → {frontmatter_map(문자열 키), body, warnings}.

  항상 성공(관용적). 프론트매터 구분자가 없으면 frontmatter=%{}, body=전체.
  """
  def parse(text) when is_binary(text) do
    case split(text) do
      {:ok, fm_block, body} ->
        {map, warnings} = parse_block(fm_block)
        {map, body, warnings}

      :no_frontmatter ->
        {%{}, text, ["프론트매터 구분자(---)가 없어 전체를 본문으로 처리합니다"]}
    end
  end

  @doc """
  frontmatter map(문자열 키) → YAML 프론트매터 문자열(--- 포함). 결정적 순서.

  권장 필드(type 먼저) → tags(리스트) → 그 외 미지 필드(키 정렬). 빈 map 도 `---\\n---\\n`.
  """
  def generate(map) when is_map(map) do
    recommended = ~w(okf_version type title description resource version valid_until timestamp)
    ordered_keys = recommended ++ (map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort())

    lines =
      ordered_keys
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "tags"))
      |> Enum.flat_map(fn key ->
        case fetch(map, key) do
          {:ok, value} -> [render_scalar(key, value)]
          :error -> []
        end
      end)

    tags_lines =
      case fetch(map, "tags") do
        {:ok, tags} when is_list(tags) and tags != [] -> [render_tags(tags)]
        _ -> []
      end

    body = Enum.join(lines ++ tags_lines, "\n")
    "---\n" <> body <> (if body == "", do: "", else: "\n") <> "---\n"
  end

  # ── 분리 ────────────────────────────────────────────────────────────

  defp split(text) do
    normalized = String.replace(text, "\r\n", "\n")

    if String.starts_with?(normalized, "---\n") or normalized == "---" do
      rest = String.replace_prefix(normalized, "---\n", "")

      case String.split(rest, ~r/\n---\n/, parts: 2) do
        [fm_block, body] -> {:ok, fm_block, body}
        # 닫는 구분자 없음 — 관용적: 전체를 프론트매터 후보로, body 빈 값.
        [_only] -> :no_frontmatter
      end
    else
      :no_frontmatter
    end
  end

  # ── 블록 파싱 ────────────────────────────────────────────────────────

  defp parse_block(block) do
    lines = String.split(block, "\n")
    do_parse(lines, %{}, [], 0)
  end

  # tags 들여쓴 블록 흡수: "tags:" 다음의 "- item" 줄들을 모은다.
  defp do_parse([], map, warnings, _idx), do: {map, Enum.reverse(warnings)}

  defp do_parse([line | rest], map, warnings, idx) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        do_parse(rest, map, warnings, idx + 1)

      # "tags:" (값 없음) → 다음 "- item" 블록 흡수.
      String.match?(trimmed, ~r/^tags:\s*$/) ->
        {items, remaining} = take_list_items(rest)
        do_parse(remaining, Map.put(map, "tags", items), warnings, idx + 1)

      # "key: value" (인라인)
      match = Regex.run(~r/^([A-Za-z0-9_\-]+):\s*(.*)$/, trimmed) ->
        [_, key, raw] = match
        value = parse_value(key, raw)
        do_parse(rest, Map.put(map, key, value), warnings, idx + 1)

      true ->
        do_parse(rest, map, ["#{idx + 1}번째 줄 파싱 실패(무시): #{trimmed}" | warnings], idx + 1)
    end
  end

  # 들여쓴 "- item" 줄들을 리스트로 흡수. 비-리스트 줄을 만나면 멈춤(remaining 반환).
  defp take_list_items(lines), do: take_list_items(lines, [])

  defp take_list_items([line | rest] = all, acc) do
    case Regex.run(~r/^\s*-\s+(.*)$/, line) do
      [_, item] -> take_list_items(rest, [unquote_str(String.trim(item)) | acc])
      nil -> {Enum.reverse(acc), all}
    end
  end

  defp take_list_items([], acc), do: {Enum.reverse(acc), []}

  # 값 파싱: tags 는 인라인 리스트도 허용, 그 외는 문자열 보존(스칼라).
  defp parse_value("tags", raw), do: parse_inline_list(raw)

  defp parse_value(_key, raw) do
    raw |> String.trim() |> unquote_str()
  end

  defp parse_inline_list(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        []

      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        trimmed
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> unquote_str()))
        |> Enum.reject(&(&1 == ""))

      true ->
        # "tags: a, b" 같은 비표준도 관용적으로 쉼표 분리.
        trimmed
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> unquote_str()))
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp unquote_str(s) do
    cond do
      String.starts_with?(s, "\"") and String.ends_with?(s, "\"") and String.length(s) >= 2 ->
        s |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(s, "'") and String.ends_with?(s, "'") and String.length(s) >= 2 ->
        s |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        s
    end
  end

  # ── 생성 ────────────────────────────────────────────────────────────

  # 문자열 키 우선, 없으면 atom 키 시도(생성 입력이 atom 키일 수 있음). nil/"" 은 미존재 취급.
  defp fetch(map, key) do
    value = Map.get(map, key) || Map.get(map, safe_atom(key))

    case value do
      nil -> :error
      "" -> :error
      v -> {:ok, v}
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp render_scalar(key, value) do
    str = to_string(value)
    "#{key}: #{maybe_quote(str)}"
  end

  defp render_tags(tags) do
    inner = tags |> Enum.map(&maybe_quote(to_string(&1))) |> Enum.join(", ")
    "tags: [#{inner}]"
  end

  # 특수문자(콜론·따옴표·앞뒤 공백) 있으면 인용.
  defp maybe_quote(str) do
    if String.contains?(str, [":", "#", "\"", "'", "["]) or str != String.trim(str) do
      "\"" <> String.replace(str, "\"", "\\\"") <> "\""
    else
      str
    end
  end
end
