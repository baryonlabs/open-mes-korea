defmodule OpenMes.Connect.DureClaw.Orchestrator do
  @moduledoc """
  오케스트레이션·정책 레이어 (레이어 ①) — DureClaw 연동의 *단일 책임* 조율 지점.

  Managed Agents 의 **lead agent** 에 대응한다. 흩어져 있던 "어느 노드에 · 무슨 모델로 ·
  무엇을 · 어떤 설비 맥락으로" 지시하는 정책을 한 곳에 모은다.

      ① 오케스트레이션·정책 (이 모듈, MES)   목적→모델/노드 · 설비 맥락 · 역할별 지시
            ↓ task.assign / task.result
      ② 전송·협력 (DureClaw 버스)            presence · Work Key(=Session) · Events
            ↓
      ③ 실행·모델 (oah-agent 노드)           backend·model = self_hosted Environment

  ## 코어 비침투

  설비 의미론적 바인딩은 **config 기반**(코어 DB 읽기 0). 더 깊은 맥락(LOT·시계열)은
  기존 조사 read 경로에 후속으로 끼운다. 이 모듈은 코어 도메인을 *참조하지 않는다*.
  """

  # ── 설비 의미론적 바인딩 (C) ─────────────────────────────────────────────
  # config 로 에이전트 ↔ 설비 목적을 잇는다(코어 미참조). 예:
  #
  #   config :open_mes, OpenMes.Connect.DureClaw,
  #     equipment_map: %{
  #       "executor@pi-zero"     => %{code: "PRESS-01", purpose: "사출기 금형온도·외관 카메라"},
  #       "builder@linux-builder" => %{code: "VISION-01", purpose: "비전 검사 GPU"}
  #     }
  @doc "에이전트 → 설비 바인딩 맵(config). 미설정 시 빈 맵."
  def equipment_map do
    :open_mes
    |> Application.get_env(OpenMes.Connect.DureClaw, [])
    |> Keyword.get(:equipment_map, %{})
  end

  @doc """
  에이전트의 설비 의미론적 맥락 한 줄. 바인딩 없으면 nil.
  "PRESS-01(사출기 금형온도·외관 카메라) 센싱 중" 형태.
  """
  def equipment_context(agent_name) do
    case Map.get(equipment_map(), agent_name) do
      %{code: code} = eq ->
        purpose = eq[:purpose]
        if purpose, do: "#{code}(#{purpose})", else: code

      _ ->
        nil
    end
  end

  # ── 에이전트별 모델 지정 (A) ─────────────────────────────────────────────
  # 에이전트마다 *명시적으로* 모델을 정한다(config). 없으면 capability 기반 기본 정책으로 폴백.
  #
  #   config :open_mes, OpenMes.Connect.DureClaw,
  #     model_map: %{
  #       "brain@hong-macbookpro" => "claude-opus-4-8",     # 종합=강한 모델
  #       "builder@docker-arm64"  => "claude-haiku-4-5",    # 1차 필터=싼 모델
  #       "builder@linux-builder" => "ollama:llama3"        # 민감=온프레미스
  #     }
  @doc "에이전트 → 모델 명시 지정 맵(config). 미설정 시 빈 맵."
  def model_map do
    :open_mes
    |> Application.get_env(OpenMes.Connect.DureClaw, [])
    |> Keyword.get(:model_map, %{})
  end

  @doc "에이전트가 쓸 모델(명시 지정 우선 → capability 기본). oah-agent 가 존중 시 적용."
  def model_for(agent_name, caps) do
    Map.get(model_map(), agent_name) || default_model(caps)
  end

  # capability → 기본 모델 (명시 지정이 없을 때). 비용·주권 정책.
  defp default_model(caps) do
    cond do
      caps_any?(caps, ["vision", "nvidia-gpu"]) -> "ollama:llama3"
      caps_any?(caps, ["camera", "edge", "gpio", "led", "sensor"]) -> "claude-haiku-4-5"
      caps_any?(caps, ["genealogy", "mes"]) -> "claude-opus-4-8"
      true -> "claude-haiku-4-5"
    end
  end

  @doc "모델 문자열 → 실행 백엔드 힌트(oah-agent 용)."
  def backend_for(agent_name, caps) do
    case model_for(agent_name, caps) do
      "ollama" <> _ -> "ollama"
      "gpt" <> _ -> "openai-sdk"
      "o1" <> _ -> "openai-sdk"
      _ -> "claude-cli"
    end
  end

  # ── 역할별 지시 생성 (C 주입 + A 모델 지정) ──────────────────────────────
  @doc """
  capability + 설비 맥락 → (역할 라벨, 지시 프롬프트, 백엔드 힌트, 모델).
  설비 바인딩이 있으면 *무엇을 센싱 중인지* 상황정보를 프롬프트에 주입한다(C).
  에이전트별 지정 모델/백엔드를 함께 반환한다(A).
  """
  def role_task(caps, lot, agent_name) do
    ctx = equipment_context(agent_name)
    ctx_line = if ctx, do: "[현재 설비: #{ctx} 센싱 중] ", else: ""

    {label, base} =
      cond do
        caps_any?(caps, ["camera", "edge", "gpio", "led", "sensor"]) ->
          {"엣지 검사", "LOT #{lot} 외관 검사: 스크래치 의심 여부와 감지 센서를 한 줄로 답해줘."}

        caps_any?(caps, ["vision", "nvidia-gpu"]) ->
          {"비전 분석", "LOT #{lot} 비전: 스크래치 점수(0~1)와 위치를 한 줄로 답해줘."}

        caps_any?(caps, ["genealogy", "mes"]) ->
          {"LOT 계보", "LOT #{lot} 계보 역추적: 공통 원자재 LOT과 영향 작업지시를 한 줄로 답해줘."}

        true ->
          {"보조 분석", "LOT #{lot} 불량 분석 보조: 핵심 한 줄."}
      end

    {label, ctx_line <> base, backend_for(agent_name, caps), model_for(agent_name, caps)}
  end

  @doc """
  목적별 선택 라우팅(A) — 자유 프롬프트를 *적합한 노드만* 고른다.
  현재는 전체 fan-out 이 기본이지만, 목적 키워드가 있으면 해당 capability 노드로 좁힌다.
  반환: 지시 대상 에이전트 리스트(부분집합).
  """
  def route(agents, prompt) do
    p = String.downcase(to_string(prompt))

    want =
      cond do
        String.contains?(p, ["비전", "vision", "이미지", "스크래치"]) -> ["vision", "nvidia-gpu", "camera"]
        String.contains?(p, ["계보", "genealogy", "lot", "자재"]) -> ["genealogy", "mes"]
        String.contains?(p, ["센서", "엣지", "edge", "온도"]) -> ["edge", "sensor", "camera", "gpio"]
        true -> :all
      end

    case want do
      :all ->
        agents

      keys ->
        matched = Enum.filter(agents, fn a -> caps_any?(a["capabilities"] || [], keys) end)
        if matched == [], do: agents, else: matched
    end
  end

  defp caps_any?(caps, keys), do: Enum.any?(keys, &(&1 in caps))
end
