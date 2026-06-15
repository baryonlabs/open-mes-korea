defmodule OpenMesWeb.Admin.Settings.SkillSettingsLive do
  @moduledoc """
  설정 — Skill(AI Tool Action) 설정(설계 23번 §B.2, 2순위 스텁).

  AI 가 쓸 수 있는 Tool Action 화이트리스트(SkillRegistry)를 표시한다.
  CLAUDE.md L93: propose_*/draft_*/suggest_* 만 등록 가능, 쓰기 액션 등록 금지.
  MVP 는 목록 표시 + on/off 표기(토글 저장은 후속 — pi).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Ai.SkillRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Skill 설정", skills: SkillRegistry.list_skills())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header
        title="Skill 설정"
        subtitle="AI 가 사용할 수 있는 Tool Action(skill) 화이트리스트. 모든 skill 은 제안만 하며 직접 쓰기는 없습니다."
      />

      <div class="mb-4 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
        등록 정책: 제안형 액션(propose_*/draft_*/suggest_*)만 등록 가능합니다. 직접 쓰기 액션은 등록할 수 없습니다.
      </div>

      <.table id="skills" rows={@skills}>
        <:col :let={s} label="액션명">{s.name}</:col>
        <:col :let={s} label="카테고리">{s.category}</:col>
        <:col :let={s} label="AI 레벨">{s.level}</:col>
        <:col :let={s} label="쓰기 여부">
          <span class={[
            "inline-flex rounded-full px-2 py-0.5 text-xs font-medium",
            if(s.writes, do: "bg-red-100 text-red-700", else: "bg-green-100 text-green-700")
          ]}>
            {if s.writes, do: "직접 쓰기", else: "제안만 (쓰기 없음)"}
          </span>
        </:col>
        <:col :let={s} label="상태">
          <.active_badge active={s.enabled} />
        </:col>
        <:action :let={_s}>
          <span class="cursor-not-allowed text-xs text-zinc-400" title="토글 저장은 후속 단계">on/off (준비중)</span>
        </:action>
      </.table>
    </.admin_shell>
    """
  end
end
