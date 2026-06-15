defmodule OpenMesWeb.Admin.Settings.McpSettingsLive do
  @moduledoc """
  설정 — MCP(Model Context Protocol) 서버 설정(설계 23번 §B.3, 2순위 스텁).

  외부 MCP 서버 연결 설정 자리. 실제 연결 코드 0(후속). 폼 스텁(저장 미연동).
  안전 경계: MCP 로 들어온 외부 도구도 AI 직접 쓰기 금지·승인 흐름이 동일 적용된다.
  """
  use OpenMesWeb.Admin.AdminLive

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "MCP 설정")}
  end

  @impl true
  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :info, "MCP 서버 연결은 후속 단계에서 활성화됩니다(현재는 스텁).")}
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
        title="MCP 설정"
        subtitle="외부 MCP(Model Context Protocol) 서버 연결 설정. 후속 단계에서 활성화됩니다."
      />

      <div class="mb-4 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-600">
        MCP 서버 연결은 후속 단계에서 활성화됩니다. AI 는 등록된 MCP 도구도 동일하게 propose→승인→적용 흐름을 거칩니다(직접 쓰기 금지).
      </div>

      <form phx-submit="save" class="max-w-lg space-y-4 rounded-lg border border-zinc-200 bg-white p-4">
        <div>
          <label class="mb-1 block text-sm font-medium text-zinc-700">서버 이름</label>
          <input
            type="text"
            name="name"
            placeholder="예: factory-tools"
            class="w-full rounded-md border-zinc-300 text-sm"
          />
        </div>
        <div>
          <label class="mb-1 block text-sm font-medium text-zinc-700">서버 URL</label>
          <input
            type="text"
            name="url"
            placeholder="https://mcp.example.com"
            class="w-full rounded-md border-zinc-300 text-sm"
          />
        </div>
        <div>
          <label class="mb-1 block text-sm font-medium text-zinc-700">인증 토큰 (선택)</label>
          <input type="password" name="token" class="w-full rounded-md border-zinc-300 text-sm" />
        </div>
        <label class="flex items-center gap-2 text-sm text-zinc-700">
          <input type="checkbox" name="active" class="rounded border-zinc-300" /> 활성
        </label>
        <.button>저장 (스텁)</.button>
      </form>
    </.admin_shell>
    """
  end
end
