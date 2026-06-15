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
  # 공통 admin 셸(사이드바·상단바·role 배지) + on_mount(current_actor/role/path 주입).
  # 카탈로그/애드온과 동일한 OMK 레이아웃을 따른다.
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Connect.DureClaw

  @poll_ms 3000

  @lot_no "A-2026-1031"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)

    {:ok,
     assign(socket,
       page_title: "DureClaw 분산 오케스트레이션",
       snap: DureClaw.snapshot(),
       lot_no: @lot_no,
       dstatus: :idle,
       dispatch: nil
     )}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, assign(socket, snap: DureClaw.snapshot())}
  end

  # 비동기 fan-out/fan-in 완료
  def handle_info({:dispatch_done, result}, socket) do
    {:noreply, assign(socket, dstatus: :dispatched, dispatch: result)}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, snap: DureClaw.snapshot())}

  # Approval Flow: propose → approve → execute(fan-out) → 수집
  def handle_event("propose_dispatch", _p, socket),
    do: {:noreply, assign(socket, dstatus: :proposed)}

  def handle_event("cancel_dispatch", _p, socket), do: {:noreply, assign(socket, dstatus: :idle)}

  def handle_event("approve_dispatch", _p, socket) do
    pid = self()
    lot = socket.assigns.lot_no
    Task.start(fn -> send(pid, {:dispatch_done, DureClaw.dispatch_analysis(lot)}) end)
    {:noreply, assign(socket, dstatus: :dispatching)}
  end

  # task.result 본문에서 사람이 읽을 요약 추출 (sim=ack, 실에이전트=emits/summary).
  defp result_summary(nil), do: "(응답 없음 — 타임아웃)"

  defp result_summary(%{} = r) do
    rich =
      r
      |> Map.drop(["task_id", "from", "event", "ts", "to", "status", "summary", "latency_ms"])
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)

    cond do
      rich != [] -> Enum.join(rich, " · ")
      r["summary"] -> r["summary"]
      true -> "완료"
    end
  end

  defp result_summary(_), do: "완료"

  defp role_icon("executor"), do: "🤖"
  defp role_icon("builder"), do: "🏗️"
  defp role_icon("analyst"), do: "🔍"
  defp role_icon("orchestrator"), do: "🎯"
  defp role_icon(_), do: "⚙️"

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
        title="DureClaw 분산 오케스트레이션"
        subtitle="분산 에이전트 협력 버스의 fleet 을 관측합니다(읽기 전용 · 3초 라이브)."
      />

      <div class="flex justify-end">
        <.link navigate="/extensions" class="text-sm text-blue-600 hover:underline">
          ← 확장 카탈로그
        </.link>
      </div>

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

      <%!-- 분석 지시 (Approval Flow: propose → approve → fan-out → 수집) --%>
      <div :if={@snap.connected} class="mb-6 rounded-lg border border-indigo-200 bg-indigo-50/40 p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-sm font-semibold text-zinc-800">분석 지시 — fleet fan-out</div>
            <div class="text-xs text-zinc-500">
              LOT <span class="font-mono">{@lot_no}</span>
              분석을 온라인 {length(@snap.agents)}개 에이전트에 동시 지시합니다.
            </div>
          </div>
          <button
            :if={@dstatus == :idle}
            phx-click="propose_dispatch"
            disabled={@snap.agents == []}
            class="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-500 disabled:opacity-40"
          >
            분석 지시 →
          </button>
        </div>

        <%!-- propose --%>
        <div :if={@dstatus == :proposed} class="mt-3 rounded-md border border-indigo-200 bg-white p-3">
          <p class="text-sm text-zinc-700">
            <span class="font-semibold">제안(propose)</span>
            — 아래 액션을 실행할까요? AI/사람 지시는 <span class="font-semibold">승인 후 실행</span>됩니다(직접 실행 X).
          </p>
          <ul class="mt-2 list-disc pl-5 text-xs text-zinc-500">
            <li :for={a <- @snap.agents}>
              {a["name"]} ← task.assign "LOT {@lot_no} 분석"
            </li>
          </ul>
          <div class="mt-3 flex gap-2">
            <button
              phx-click="approve_dispatch"
              class="rounded-lg bg-rose-600 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-500"
            >
              승인 → 지시 실행
            </button>
            <button
              phx-click="cancel_dispatch"
              class="rounded-lg border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100"
            >
              취소
            </button>
          </div>
        </div>

        <%!-- dispatching --%>
        <div :if={@dstatus == :dispatching} class="mt-3 animate-pulse text-sm text-zinc-500">
          ▶ fan-out 지시 전송 + 결과 수집(fan-in) 중…
        </div>

        <%!-- dispatched: fan-in 결과 --%>
        <div
          :if={@dstatus == :dispatched and @dispatch}
          class="mt-3 rounded-md border border-emerald-200 bg-white p-3"
        >
          <div class="mb-2 text-sm font-semibold text-zinc-800">
            ✅ 지시 완료 · fan-in 수집 (work_key <span class="font-mono text-xs">{@dispatch.work_key}</span>)
          </div>
          <div class="space-y-1">
            <div :for={d <- @dispatch.dispatched} class="flex items-start gap-2 text-xs">
              <span class="font-mono font-semibold text-zinc-700">{role_icon(d.role)} {d.agent}</span>
              <span class="text-zinc-400">→</span>
              <span class="text-zinc-600">
                {result_summary(d.result)}
              </span>
            </div>
          </div>
          <p class="mt-2 text-[11px] text-zinc-400">
            sim 에이전트는 ack 응답만 반환합니다. 실제 데이터(비전 점수·LOT 계보)는 물리 에이전트(Pi·GPU)가
            실작업하거나 시나리오 emits 주입 시 수집됩니다.
          </p>
          <button
            phx-click="cancel_dispatch"
            class="mt-2 text-xs text-zinc-500 underline hover:text-zinc-700"
          >
            다시
          </button>
        </div>
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
        <div :for={a <- @snap.agents} class="rounded-lg border border-zinc-200 bg-white p-4">
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
    </.admin_shell>
    """
  end
end
