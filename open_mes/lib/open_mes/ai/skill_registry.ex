defmodule OpenMes.Ai.SkillRegistry do
  @moduledoc """
  AI Tool Action(skill) 화이트리스트 — 설계 23번 §B.2.

  CLAUDE.md L93: 허용된 Tool Action 만 등록 가능(propose_*/draft_*/suggest_*).
  쓰기 액션(writes: true)은 등록 금지 정책 — 모든 등록 skill 은 제안만 하며 직접 쓰기 0.

  얇은 모듈(상태 없음). MVP 는 1개 액션만 등록.
  """

  @skills [
    %{
      id: "propose_line_config",
      name: "AI 라인 구성 제안",
      category: "production_line",
      level: "Level 3 (승인 필요)",
      writes: false,
      enabled: true,
      description: "자연어 라인 구성 변경안 제안. 직접 쓰기 없음, 승인 후 적용."
    }
  ]

  @doc "등록된 AI tool action 목록."
  def list_skills, do: @skills

  @doc "id 로 skill 조회."
  def get_skill(id), do: Enum.find(@skills, &(&1.id == id))

  @doc "id 가 등록된(허용된) skill 인가 — Tool Action 화이트리스트 검사."
  def allowed?(id), do: Enum.any?(@skills, &(&1.id == id and &1.enabled))
end
