defmodule OpenMes.Ai.ClaudeProvider do
  @moduledoc """
  Claude API Provider(설계 23번 §A.5, 2순위) — ANTHROPIC_API_KEY 있을 때만 사용.

  MockProvider 와 동일하게 context map + prompt 만 받는다(Repo 접근 불가 — 구조적 안전).
  system 프롬프트로 "context.available_processes 에서만 골라 diff JSON 반환, 공정 발명 금지"
  를 강제한다. 키 없거나 요청 실패 시 {:error, _} → UI 가 "AI 제안 실패" 처리.

  pi: 키 없는 MVP 에서는 Provider.active/0 가 이 모듈을 선택하지 않으므로 호출되지 않는다.
  인터페이스 확정 + req 호출 골격만 둔다(실호출은 키 있을 때).
  """
  @behaviour OpenMes.Ai.Provider

  @api_url "https://api.anthropic.com/v1/messages"
  # 최신 Opus(기본 권장). ANTHROPIC_MODEL 환경변수로 override 가능(예: claude-sonnet-4-6).
  @default_model "claude-opus-4-8"
  @anthropic_version "2023-06-01"

  defp model, do: System.get_env("ANTHROPIC_MODEL") || @default_model

  @impl true
  def propose_line_diff(context, prompt) when is_map(context) and is_binary(prompt) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] ->
        {:error, :no_api_key}

      key ->
        request(context, prompt, key)
    end
  end

  # ── 종합 조사(investigate/2) — Level 1 읽기. context+query 만(Repo 불가). 부수효과 0. ──

  @impl true
  def investigate(context, query) when is_map(context) and is_binary(query) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] -> {:error, :no_api_key}
      key -> investigate_request(context, query, key)
    end
  end

  defp investigate_request(context, query, key) do
    body = %{
      model: model(),
      max_tokens: 1024,
      system: investigate_system_prompt(),
      messages: [
        %{
          role: "user",
          content:
            "조사 컨텍스트(JSON):\n#{Jason.encode!(context)}\n\n질의: #{query}\n\n위 컨텍스트 범위 안의 데이터만 근거로 한국어로 분석하라."
        }
      ]
    }

    req =
      Req.new(
        url: @api_url,
        headers: [
          {"x-api-key", key},
          {"anthropic-version", @anthropic_version},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 30_000
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: resp}} -> parse_investigation(resp, context)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp investigate_system_prompt do
    """
    너는 MES 설비 종합 조사 보조자다. 사용자가 준 조사 컨텍스트(시계열 통계 요약 + 미디어 메타 + 생산 실적 + 지식 문서(knowledge))만을 근거로 분석한다.
    컨텍스트에 없는 사실을 절대 발명하지 마라(없으면 "데이터 없음"이라고 한다).
    조사 컨텍스트의 knowledge 문서(표준작업서·설비매뉴얼·트러블슈팅 등)를 근거로 인용할 때는 해당 문서의 resource 를 함께 제시하라. 컨텍스트에 없는 문서를 인용하지 마라.
    너는 읽기 전용이며 어떤 변경/실행도 제안하지 않는다. 한국어로 간결한 분석 요약을 제공한다.
    """
  end

  defp parse_investigation(%{"content" => content}, context) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    {:ok,
     %{
       analysis: text,
       findings: [],
       referenced: Map.get(context, :referenced, %{})
     }}
  end

  defp parse_investigation(_, _), do: {:error, :invalid_response}

  defp request(context, prompt, key) do
    body = %{
      model: model(),
      max_tokens: 1024,
      system: system_prompt(context),
      messages: [%{role: "user", content: prompt}]
    }

    req =
      Req.new(
        url: @api_url,
        headers: [
          {"x-api-key", key},
          {"anthropic-version", @anthropic_version},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 30_000
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: resp}} -> parse_response(resp, context)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # context.available_processes 화이트리스트만 허용하도록 강제하는 system 프롬프트.
  defp system_prompt(context) do
    codes =
      context
      |> Map.get(:available_processes, [])
      |> Enum.map_join(", ", & &1.process_code)

    """
    너는 MES 생산라인 구성 보조자다. 사용자의 자연어 지시를 라인 구성 변경 diff(JSON)로만 변환한다.
    반드시 다음 process_code 화이트리스트에서만 골라라(없는 공정 발명 절대 금지): #{codes}.
    출력은 JSON 객체 하나: {"diff": [...ops...], "summary": "한국어 요약"}.
    op 형식: {"op":"add_step","process_code":"...","after_process_code":"...|null"} |
             {"op":"reorder","process_code":"...","to":"last|first"} |
             {"op":"remove_step","process_code":"..."}.
    직접 적용하지 말고 제안만 한다.
    """
  end

  defp parse_response(%{"content" => content}, context) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    with {:ok, json} <- extract_json(text),
         %{"diff" => diff} <- json do
      referenced = %{
        line: Map.get(context, :line),
        current_step_count: length(Map.get(context, :current_steps, [])),
        available_process_count: length(Map.get(context, :available_processes, [])),
        parser: "claude_#{model()}"
      }

      {:ok, %{diff: diff, summary: Map.get(json, "summary", ""), referenced: referenced}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_response(_, _), do: {:error, :invalid_response}

  defp extract_json(text) do
    case Regex.run(~r/\{.*\}/su, text) do
      [json_str] -> Jason.decode(json_str)
      _ -> {:error, :no_json}
    end
  end
end
