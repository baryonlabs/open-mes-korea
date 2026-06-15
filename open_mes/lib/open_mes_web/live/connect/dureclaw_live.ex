defmodule OpenMesWeb.Connect.DureClawLive do
  @moduledoc """
  EXT-5 연동 허브 — DureClaw 분산 에이전트 fleet 관측 화면(읽기 전용).

  버스 presence·Work Key·health 를 3초마다 폴링해 카드로 렌더한다.
  데이터 소스는 `OpenMes.Connect.DureClaw.snapshot/0`(읽기 전용) 하나뿐이다.

  ## pi 준수

    - 외부 차트/실시간 라이브러리 도입 안 함. LiveView 폴링 + 서버 렌더.
    - 도메인 쓰기 0(AuditLog/Outbox 무관). 버스 조회 + 렌더뿐.

  라우트(확장 enabled 시에만 등록):

      if OpenMes.Connect.DureClaw.Extension.enabled?() do
        scope "/extensions", OpenMesWeb.Connect do
          pipe_through :browser
          live "/dureclaw", DureClawLive, :index
        end
      end
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Connect.DureClaw

  @poll_ms 3000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)
    {:ok, assign(socket, page_title: "DureClaw 분산 오케스트레이션", snap: DureClaw.snapshot())}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, assign(socket, snap: DureClaw.snapshot())}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, snap: DureClaw.snapshot())}

  defp role_icon("executor"), do: "🤖"
  defp role_icon("builder"), do: "🏗️"
  defp role_icon("analyst"), do: "🔍"
  defp role_icon("orchestrator"), do: "🎯"
  defp role_icon(_), do: "⚙️"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-4 py-8">
      <header class="mb-6 flex items-start justify-between">
        <div>
          <h1 class="text-2xl font-bold text-zinc-900">🔌 DureClaw 분산 오케스트레이션</h1>
          <p class="mt-1 text-sm text-zinc-500">
            분산 에이전트 협력 버스의 fleet 을 관측합니다(읽기 전용 · 3초 라이브).
          </p>
        </div>
        <.link navigate="/extensions" class="text-sm text-blue-600 hover:underline">← 확장 카탈로그</.link>
      </header>

      <%!-- 연결 상태 --%>
      <div class={[
        "mb-6 flex items-center gap-3 rounded-lg border p-4",
        @snap.connected && "border-emerald-200 bg-emerald-50",
        !@snap.connected && "border-zinc-200 bg-zinc-50"
      ]}>
        <span class="text-xl">{if @snap.connected, do: "🟢", else: "⚪"}</span>
        <div class="text-sm">
          <div class="font-semibold text-zinc-800">
            {if @snap.connected, do: "버스 연결됨", else: "버스 미연결 (BUS_URL 미설정)"}
          </div>
          <div :if={@snap.connected} class="font-mono text-xs text-zinc-500">
            {@snap.bus_url} · v{@snap.health["version"]} · work_keys {@snap.health["work_keys"]}
          </div>
        </div>
        <button
          phx-click="refresh"
          class="ml-auto rounded border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100"
        >
          새로고침
        </button>
      </div>

      <%!-- 온라인 에이전트 --%>
      <h2 class="mb-2 text-sm font-semibold text-zinc-700">
        온라인 에이전트 <span class="text-zinc-400">({length(@snap.agents)})</span>
      </h2>
      <div
        :if={@snap.agents == []}
        class="mb-6 rounded-lg border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-400"
      >
        연결된 에이전트 없음 — fleet(엣지 Pi·시뮬 워커)이 버스에 JOIN 하면 여기 표시됩니다.
      </div>
      <div class="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div
          :for={a <- @snap.agents}
          class="rounded-lg border border-zinc-200 bg-white p-4"
        >
          <div class="flex items-center justify-between">
            <span class="font-mono font-semibold text-zinc-900">
              {role_icon(a["role"])} {a["name"]}
            </span>
            <span class="rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-500">{a["role"]}</span>
          </div>
          <div class="mt-2 flex flex-wrap gap-1">
            <span
              :for={c <- a["capabilities"] || []}
              class="rounded bg-blue-50 px-2 py-0.5 text-xs text-blue-700"
            >
              {c}
            </span>
          </div>
          <div class="mt-2 font-mono text-xs text-zinc-400">
            model {a["preferred_model"]} · {a["machine"]}
          </div>
        </div>
      </div>

      <%!-- Work Keys --%>
      <h2 class="mb-2 text-sm font-semibold text-zinc-700">
        Work Keys <span class="text-zinc-400">({length(@snap.work_keys)})</span>
      </h2>
      <div class="flex flex-wrap gap-2">
        <span
          :for={wk <- Enum.take(@snap.work_keys, 16)}
          class="rounded bg-zinc-100 px-2 py-1 font-mono text-xs text-zinc-600"
        >
          {if is_map(wk), do: wk["work_key"] || wk["key"], else: wk}
        </span>
      </div>
    </div>
    """
  end
end
