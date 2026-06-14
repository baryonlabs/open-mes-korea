defmodule OpenMes.Ai.Provider do
  @moduledoc """
  LLM 어댑터 behaviour — 설계 23번 §A.5.

  AI 안전 불변식(구조적 차단): 구현체는 **plain map context 와 prompt 문자열만** 받는다.
  Repo/Ecto/컨텍스트 모듈을 인자로 받지 못하므로 **구조적으로 DB 쓰기 불가**.
  AI 의 산출물은 선언적 diff(op 목록)일 뿐 부수효과 0.

  구현체:
    - `MockProvider`  : 한국어 규칙 파서(기본 — 키 없을 때, 외부 의존 0).
    - `ClaudeProvider`: Anthropic API(ANTHROPIC_API_KEY 있을 때만).

  diff op 스키마(proposed_action.ops):
      %{"op" => "add_step", "process_code" => "P-PREHEAT", "equipment_code" => nil, "after_sequence" => 3}
      %{"op" => "reorder", "process_code" => "P-PACK", "to" => "last"}
      %{"op" => "remove_step", "process_code" => "P-OLD"}
  """

  @type context :: map()
  @type diff_op :: map()
  @type result :: %{diff: [diff_op()], summary: String.t(), referenced: map()}

  @doc """
  context(plain map) + 자연어 prompt → diff op 목록 제안.
  Repo 접근 불가(인자에 없음). 부수효과 0 — 데이터(제안)만 반환.
  """
  @callback propose_line_diff(context(), prompt :: String.t()) :: {:ok, result()} | {:error, term()}

  @typedoc "조사 결과(Level 1 읽기 — 부수효과 0). analysis: 한국어 요약, findings: 발견점, referenced: 근거."
  @type investigation_result :: %{
          analysis: String.t(),
          findings: [map()],
          referenced: map()
        }

  @doc """
  종합 조사: context(plain map — 시계열요약+미디어메타+생산) + 자연어 query → 분석 요약.
  Repo 접근 불가(인자에 없음). **읽기 전용 — 부수효과 0**. 데이터(분석 텍스트)만 반환.
  """
  @callback investigate(context(), query :: String.t()) ::
              {:ok, investigation_result()} | {:error, term()}

  @doc """
  활성 provider 모듈. config 의 :impl 이 있으면 그것을, 없으면 키 존재 여부로 결정.
  ANTHROPIC_API_KEY 있으면 ClaudeProvider, 없으면 MockProvider(기본).
  """
  def active do
    case Application.get_env(:open_mes, __MODULE__, [])[:impl] do
      nil -> resolve_default()
      impl -> impl
    end
  end

  defp resolve_default do
    if System.get_env("ANTHROPIC_API_KEY") in [nil, ""] do
      OpenMes.Ai.MockProvider
    else
      OpenMes.Ai.ClaudeProvider
    end
  end

  @doc "활성 provider 식별 라벨(감사/UI 표시용)."
  def label(OpenMes.Ai.MockProvider), do: "mock"
  def label(OpenMes.Ai.ClaudeProvider), do: "claude"
  def label(mod) when is_atom(mod), do: inspect(mod)
end
