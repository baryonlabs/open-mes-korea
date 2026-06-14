defmodule OpenMes.Ai.MockProvider do
  @moduledoc """
  Mock Provider — 한국어 규칙 기반 자연어 파서(설계 23번 §A.5). 외부 의존 0, 키 없이 동작.

  목표는 "완벽한 NLU" 가 아니라 **승인 흐름·diff·감사·적용 전 과정을 키 없이 데모**하는 것.
  context map(`ProductionLine.ai_context/2` 반환)과 prompt 문자열만 받으며 Repo 접근 불가.

  지원 한국어 패턴(부분일치 — 공정명/공정코드를 available_processes 에서 매칭):
    - "X 다음에 Y 추가" / "X 뒤에 Y 공정 추가" → add_step(Y, after=X)
    - "Y를 마지막으로" / "Y 맨 뒤로"            → reorder(Y → last)
    - "X 삭제" / "X 빼기" / "X 제거"            → remove_step(X)

  available_processes 화이트리스트에 없는 공정명은 diff 에 넣지 않고 summary 에 경고한다.
  """
  @behaviour OpenMes.Ai.Provider

  @impl true
  def propose_line_diff(context, prompt) when is_map(context) and is_binary(prompt) do
    available = Map.get(context, :available_processes, [])
    current = Map.get(context, :current_steps, [])

    # 문장을 쉼표/줄바꿈으로 분리해 지시 단위로 파싱.
    clauses =
      prompt
      |> String.split(~r/[,\n]/u, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {ops, notes} =
      Enum.reduce(clauses, {[], []}, fn clause, {ops_acc, notes_acc} ->
        case parse_clause(clause, available, current) do
          {:ok, op, note} -> {ops_acc ++ [op], notes_acc ++ [note]}
          {:skip, note} -> {ops_acc, notes_acc ++ [note]}
        end
      end)

    summary = build_summary(ops, notes)

    referenced = %{
      line: Map.get(context, :line),
      current_step_count: length(current),
      available_process_count: length(available),
      available_equipment_count: length(Map.get(context, :available_equipment, [])),
      parser: "mock_rule_based"
    }

    {:ok, %{diff: ops, summary: summary, referenced: referenced}}
  end

  # ── 종합 조사(investigate/2) — Level 1 읽기. 규칙 기반 한국어 요약. 부수효과 0. ──

  @impl true
  def investigate(context, query) when is_map(context) and is_binary(query) do
    subject = Map.get(context, :subject, %{})
    ts = Map.get(context, :timeseries, %{})
    media = Map.get(context, :media, %{})
    production = Map.get(context, :production, %{})

    knowledge = Map.get(context, :knowledge, %{})

    metrics = Map.get(ts, :metrics, [])
    equip_name = Map.get(subject, :equipment_name) || Map.get(subject, :equipment_code) || "설비"
    period_label = context |> Map.get(:period, %{}) |> Map.get(:label, "선택 기간")

    metric_findings = Enum.map(metrics, &metric_finding/1)
    media_finding = media_finding(media)
    production_finding = production_finding(production)
    knowledge_findings = knowledge_findings(knowledge)

    findings =
      metric_findings ++
        List.wrap(media_finding) ++ List.wrap(production_finding) ++ knowledge_findings

    analysis =
      build_analysis(equip_name, period_label, metrics, media, production, knowledge)

    referenced = Map.get(context, :referenced, %{})

    {:ok, %{analysis: analysis, findings: findings, referenced: referenced}}
  end

  defp metric_finding(m) do
    trend_kr = trend_label(Map.get(m, :trend))
    anomaly = Map.get(m, :anomaly_count, 0)

    %{
      kind: "timeseries",
      metric: Map.get(m, :metric_key),
      note: "#{trend_kr} 추세, 평균 #{fmt(Map.get(m, :avg))}#{unit_suffix(m)}, 이상치 #{anomaly}건"
    }
  end

  defp media_finding(media) do
    total = Map.get(media, :total, 0)
    if total > 0 do
      counts = Map.get(media, :counts_by_type, %{})

      %{
        kind: "media",
        note:
          "미디어 #{total}건(영상 #{Map.get(counts, "video", 0)}·이미지 #{Map.get(counts, "image", 0)}·음성 #{Map.get(counts, "audio", 0)}) — 이상 시각대 검토 대상"
      }
    end
  end

  defp production_finding(production) do
    summary = Map.get(production, :process_summary)

    if is_map(summary) do
      rate = Map.get(summary, :defect_rate, 0.0)
      level = if rate >= 0.1, do: "위험", else: if(rate >= 0.05, do: "주의", else: "양호")
      %{kind: "production", note: "불량률 #{fmt_pct(rate)}(#{level})"}
    end
  end

  # 지식 문서(OKF) findings — 각 문서를 인용 근거(resource)와 함께 표기. 읽기·인용만.
  defp knowledge_findings(knowledge) do
    knowledge
    |> Map.get(:documents, [])
    |> Enum.map(fn d ->
      %{
        kind: "knowledge",
        title: Map.get(d, :title),
        resource: Map.get(d, :resource),
        note: "[#{Map.get(d, :okf_type)}] #{Map.get(d, :title)} (#{Map.get(d, :resource)}) 참조"
      }
    end)
  end

  defp build_analysis(equip_name, period_label, metrics, media, production, knowledge) do
    ts_part =
      case metrics do
        [] ->
          "#{equip_name}의 #{period_label} 시계열 측정 데이터가 없습니다."

        _ ->
          rising = Enum.filter(metrics, &(Map.get(&1, :trend) == "rising"))
          anomalies = Enum.reduce(metrics, 0, &(&2 + Map.get(&1, :anomaly_count, 0)))

          rising_note =
            if rising == [],
              do: "뚜렷한 상승 추세 지표는 없습니다.",
              else:
                "상승 추세 지표: " <>
                  Enum.map_join(rising, ", ", &"#{Map.get(&1, :metric_key)}(평균 #{fmt(Map.get(&1, :avg))}#{unit_suffix(&1)})") <>
                  "."

          "#{equip_name}의 #{period_label} 측정 지표 #{length(metrics)}종을 요약했습니다. #{rising_note} 전체 이상치 #{anomalies}건."
      end

    media_part =
      case Map.get(media, :total, 0) do
        0 -> "해당 기간 수집된 미디어는 없습니다."
        n -> "같은 기간 미디어 #{n}건이 수집되었습니다(이상 시각대 영상 교차 검토 권장)."
      end

    prod_part =
      case Map.get(production, :process_summary) do
        %{defect_rate: rate} = s ->
          "생산 실적은 양품 #{Map.get(s, :good, 0)}·불량 #{Map.get(s, :defect, 0)}, 불량률 #{fmt_pct(rate)}입니다."

        _ ->
          "생산 실적 데이터가 없습니다."
      end

    correlation =
      if has_rising?(metrics) and defect_elevated?(production),
        do: " 지표 상승과 불량률 상승의 상관 가능성을 점검 권장합니다.",
        else: ""

    knowledge_part = knowledge_part(knowledge)

    "[조사 결과] " <> ts_part <> " " <> media_part <> " " <> prod_part <> correlation <> knowledge_part
  end

  # 관련 OKF 지식 문서를 분석 요약에 반영(개수 + 제목 + resource 인용). 컨텍스트에 없으면 미언급.
  defp knowledge_part(knowledge) do
    docs = Map.get(knowledge, :documents, [])

    case docs do
      [] ->
        ""

      docs ->
        titles =
          Enum.map_join(docs, ", ", fn d ->
            "#{Map.get(d, :title)}(#{Map.get(d, :resource)})"
          end)

        " 관련 지식 문서 #{length(docs)}건을 참조했습니다: #{titles}."
    end
  end

  defp has_rising?(metrics), do: Enum.any?(metrics, &(Map.get(&1, :trend) == "rising"))

  defp defect_elevated?(production) do
    case Map.get(production, :process_summary) do
      %{defect_rate: rate} -> rate >= 0.05
      _ -> false
    end
  end

  defp trend_label("rising"), do: "상승"
  defp trend_label("falling"), do: "하락"
  defp trend_label(_), do: "안정"

  defp unit_suffix(m) do
    case Map.get(m, :unit) do
      u when is_binary(u) and u != "" -> " #{u}"
      _ -> ""
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: Float.round(n, 2) |> Float.to_string()
  defp fmt(n), do: to_string(n)

  defp fmt_pct(nil), do: "0%"
  defp fmt_pct(r) when is_number(r), do: "#{Float.round(r * 100, 2)}%"
  defp fmt_pct(_), do: "0%"

  # ── 절(clause) 파싱 ───────────────────────────────────────────────────

  defp parse_clause(clause, available, _current) do
    cond do
      # "X 다음에 Y 추가" / "X 뒤에 Y (공정) 추가"
      m = Regex.run(~r/(.+?)\s*(?:다음에|뒤에)\s*(.+?)(?:\s*공정)?\s*(?:추가|넣)/u, clause) ->
        [_, after_label, add_label] = m
        handle_add(clause, add_label, after_label, available)

      # 단순 "Y 추가"(앞 절 없음) → 맨 뒤 추가
      m = Regex.run(~r/^(.+?)(?:\s*공정)?\s*(?:추가|넣)/u, clause) ->
        [_, add_label] = m
        handle_add(clause, add_label, nil, available)

      # "Y를 마지막으로" / "Y 맨 뒤로" / "Y 마지막"
      m = Regex.run(~r/(.+?)(?:을|를)?\s*(?:맨\s*)?(?:마지막|뒤로|끝)/u, clause) ->
        [_, label] = m
        handle_reorder(clause, label, "last", available)

      # "X 삭제" / "X 빼기" / "X 제거"
      m = Regex.run(~r/(.+?)(?:을|를)?\s*(?:삭제|빼|제거)/u, clause) ->
        [_, label] = m
        handle_remove(clause, label, available)

      true ->
        {:skip, "해석하지 못한 지시: \"#{clause}\""}
    end
  end

  defp handle_add(clause, add_label, after_label, available) do
    case match_process(add_label, available) do
      nil ->
        {:skip, "\"#{String.trim(add_label)}\" 공정을 선택 가능 목록에서 찾지 못했습니다(추가 무시)."}

      proc ->
        op = %{
          "op" => "add_step",
          "process_code" => proc.process_code,
          "equipment_code" => nil,
          "after_process_code" => after_label && resolve_after(after_label, available)
        }

        note =
          if after_label,
            do: "\"#{proc.name}\" 공정을 \"#{String.trim(after_label)}\" 다음에 추가",
            else: "\"#{proc.name}\" 공정을 맨 뒤에 추가"

        _ = clause
        {:ok, op, note}
    end
  end

  defp handle_reorder(_clause, label, to, available) do
    case match_process(label, available) do
      nil ->
        {:skip, "\"#{String.trim(label)}\" 공정을 찾지 못했습니다(순서변경 무시)."}

      proc ->
        op = %{"op" => "reorder", "process_code" => proc.process_code, "to" => to}
        {:ok, op, "\"#{proc.name}\" 공정을 #{if to == "last", do: "맨 뒤로", else: to} 이동"}
    end
  end

  defp handle_remove(_clause, label, available) do
    case match_process(label, available) do
      nil ->
        {:skip, "\"#{String.trim(label)}\" 공정을 찾지 못했습니다(삭제 무시)."}

      proc ->
        op = %{"op" => "remove_step", "process_code" => proc.process_code}
        {:ok, op, "\"#{proc.name}\" 공정 삭제"}
    end
  end

  # after_process_code 는 라벨로 매칭 시도(못 찾으면 nil → 맨 뒤 추가).
  defp resolve_after(after_label, available) do
    case match_process(after_label, available) do
      nil -> nil
      proc -> proc.process_code
    end
  end

  # 라벨(부분일치)을 available_processes 의 process_name/code 와 매칭(화이트리스트).
  defp match_process(label, available) do
    norm = label |> String.trim() |> String.downcase()

    Enum.find(available, fn p ->
      name = String.downcase(p.name || "")
      code = String.downcase(p.process_code || "")
      String.contains?(name, norm) or String.contains?(norm, name) or
        String.contains?(code, norm) or norm == code
    end)
  end

  defp build_summary([], notes) do
    "변경안을 생성하지 못했습니다. " <> Enum.join(notes, " / ")
  end

  defp build_summary(ops, notes) do
    "Mock 규칙 파서가 #{length(ops)}개 변경안을 생성했습니다. " <> Enum.join(notes, " / ")
  end
end
