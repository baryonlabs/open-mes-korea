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

  @default_prompt "LOT A-2026-1031 외관 불량 원인을 역할별로 분석해줘 (비전 점수·LOT 계보·엣지 이미지)"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :poll, @poll_ms)
      # 통신·대화 피드는 3초 폴링이 아니라 PubSub 실시간 push 로 갱신.
      Phoenix.PubSub.subscribe(OpenMes.PubSub, OpenMes.Connect.DureClaw.EventLog.topic())
    end

    {:ok,
     assign(socket,
       page_title: "DureClaw 분산 오케스트레이션",
       snap: DureClaw.snapshot(),
       prompt: @default_prompt,
       lot_no: "A-2026-1031",
       dstatus: :idle,
       dispatch: nil,
       istatus: :idle,
       inv: nil,
       cryst: DureClaw.crystallization_stats(),
       mon: false,
       events: DureClaw.recent_events()
     )}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)

    # 노드 상황 보드·대시보드만 3초 폴링. 통신 피드(events)는 PubSub push 로 별도 갱신.
    {:noreply, assign(socket, snap: DureClaw.snapshot(), cryst: DureClaw.crystallization_stats())}
  end

  # 통신·대화 이벤트 실시간 push — 기록 즉시 피드 맨 앞에 추가(폴링 지연 0).
  def handle_info({:dureclaw_event, ev}, socket) do
    {:noreply, assign(socket, events: [ev | socket.assigns.events] |> Enum.take(60))}
  end

  # 비동기 fan-out/fan-in 완료
  def handle_info({:dispatch_done, result}, socket) do
    {:noreply, assign(socket, dstatus: :dispatched, dispatch: result)}
  end

  def handle_info({:inv_done, result}, socket) do
    # 결정화 재사용(캐시 히트)은 hits 를 증가시키므로 대시보드도 갱신.
    {:noreply,
     assign(socket,
       istatus: :done,
       inv: result,
       cryst: DureClaw.crystallization_stats()
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, snap: DureClaw.snapshot(), events: DureClaw.recent_events())}

  def handle_event("toggle_mon", _p, socket),
    do: {:noreply, assign(socket, mon: not socket.assigns.mon, events: DureClaw.recent_events())}

  # 불량 조사 (역할별 차등 지시 → fan-in → 종합) — RSI 1차 leg
  def handle_event("investigate", _p, socket) do
    pid = self()
    lot = socket.assigns.lot_no
    Task.start(fn -> send(pid, {:inv_done, DureClaw.dispatch_investigation(lot)}) end)
    {:noreply, assign(socket, istatus: :running, inv: nil)}
  end

  # 승인 → 결정 동결(결정화). 다음 같은 패턴 불량은 LLM 0회.
  def handle_event("freeze_decision", _p, socket) do
    inv = socket.assigns.inv

    if is_map(inv) and inv[:suggest] do
      DureClaw.crystallize(inv.lot, inv.suggest, llm_ms: inv[:llm_ms], approved_by: "manager")
    end

    {:noreply, assign(socket, istatus: :frozen, cryst: DureClaw.crystallization_stats())}
  end

  def handle_event("forget_skill", _p, socket) do
    DureClaw.forget(socket.assigns.lot_no)
    {:noreply, assign(socket, istatus: :idle, inv: nil, cryst: DureClaw.crystallization_stats())}
  end

  def handle_event("reset_inv", _p, socket),
    do: {:noreply, assign(socket, istatus: :idle, inv: nil)}

  # Approval Flow: propose → approve → execute(fan-out) → 수집
  def handle_event("propose_dispatch", %{"prompt" => prompt}, socket) do
    if String.trim(prompt) == "" do
      {:noreply, socket}
    else
      {:noreply, assign(socket, prompt: prompt, dstatus: :proposed)}
    end
  end

  def handle_event("cancel_dispatch", _p, socket), do: {:noreply, assign(socket, dstatus: :idle)}

  def handle_event("approve_dispatch", _p, socket) do
    pid = self()
    prompt = socket.assigns.prompt
    Task.start(fn -> send(pid, {:dispatch_done, DureClaw.dispatch_analysis(prompt)}) end)
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

  # 1회차 LLM(ms) 대비 캐시 히트(µs) 가속 배수 (콤마 포맷).
  defp speedup(nil, _), do: "—"
  defp speedup(_, hit_us) when not is_integer(hit_us) or hit_us <= 0, do: "—"

  defp speedup(llm_ms, hit_us) do
    (llm_ms * 1000 / hit_us)
    |> round()
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  # 절감 시간 사람이 읽기 좋게(ms→s/m). 천단위 콤마.
  defp fmt_ms(nil), do: "0ms"
  defp fmt_ms(ms) when ms < 1000, do: "#{commafy(ms)}ms"
  defp fmt_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp fmt_ms(ms), do: "#{Float.round(ms / 60_000, 1)}분"

  defp commafy(n) when is_integer(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp commafy(n), do: to_string(n)

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
        <div class="ml-auto flex items-center gap-2">
          <a
            :if={@snap[:dashboard_url]}
            href={@snap.dashboard_url}
            target="_blank"
            rel="noopener noreferrer"
            class="rounded-lg bg-indigo-600 px-3 py-1 text-xs font-semibold text-white hover:bg-indigo-500"
          >
            버스 대시보드 ↗
          </a>
          <button
            phx-click="toggle_mon"
            class={[
              "rounded-lg px-3 py-1 text-xs font-semibold",
              @mon && "bg-zinc-900 text-white hover:bg-zinc-700",
              !@mon && "border border-zinc-300 text-zinc-700 hover:bg-zinc-100"
            ]}
          >
            🔍 디버그 모니터
          </button>
          <button
            phx-click="refresh"
            class="rounded border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100"
          >
            새로고침
          </button>
        </div>
      </div>

      <%!-- 🔍 디버그 모니터 — 노드 상황 + 통신·대화 피드 (Observer 의도를 원격 fleet 용 웹으로) --%>
      <div
        :if={@mon and @snap.connected}
        class="mb-6 rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-zinc-200"
      >
        <div class="mb-3 flex items-center justify-between">
          <div class="text-sm font-bold">🔍 디버그 모니터 — fleet 상태 · 통신 (라이브 3초)</div>
          <div class="font-mono text-xs text-zinc-500">
            remote nodes ≠ BEAM procs → Observer 대신 웹 트레이스
          </div>
        </div>

        <%!-- 노드 상황 보드 --%>
        <div class="mb-3 text-xs font-semibold text-zinc-400">▸ 노드 상황 (각 엣지가 무엇을 센싱/실행 중인가)</div>
        <div class="mb-4 overflow-hidden rounded-lg border border-zinc-700">
          <table class="w-full text-left text-xs">
            <thead class="bg-zinc-800 text-zinc-400">
              <tr>
                <th class="px-3 py-1.5 font-medium">노드</th>
                <th class="px-3 py-1.5 font-medium">role</th>
                <th class="px-3 py-1.5 font-medium">설비 상황</th>
                <th class="px-3 py-1.5 font-medium">model</th>
                <th class="px-3 py-1.5 font-medium">conn</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={a <- @snap.agents} class="border-t border-zinc-800">
                <td class="px-3 py-1.5 font-mono text-emerald-300">{a["name"]}</td>
                <td class="px-3 py-1.5 text-zinc-400">{a["role"]}</td>
                <td class="px-3 py-1.5">
                  <span :if={DureClaw.node_situation(a["name"])} class="text-amber-300">
                    🏭 {DureClaw.node_situation(a["name"])} 센싱 중
                  </span>
                  <span :if={!DureClaw.node_situation(a["name"])} class="text-zinc-600">
                    (설비 미바인딩)
                  </span>
                </td>
                <td class="px-3 py-1.5">
                  <span class="rounded bg-indigo-500/20 px-1.5 py-0.5 font-mono text-indigo-300">
                    {DureClaw.node_model(a["name"], a["capabilities"] || [])}
                  </span>
                </td>
                <td class="px-3 py-1.5 font-mono text-zinc-600">{a["phx_ref"]}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- 통신·대화 피드 --%>
        <div class="mb-2 text-xs font-semibold text-zinc-400">▸ 통신·대화 피드 (오케스트레이터 ⇄ 노드, 최신순)</div>
        <div class="max-h-72 space-y-1 overflow-y-auto rounded-lg bg-black/40 p-2 font-mono text-xs">
          <div :if={@events == []} class="px-2 py-3 text-center text-zinc-600">
            아직 통신 없음 — 불량 조사/분석 지시를 누르면 task.assign / task.result 가 흐릅니다.
          </div>
          <div :for={e <- @events} class="flex items-start gap-2 px-1 py-0.5">
            <span class="text-zinc-600">{e.at}</span>
            <span :if={e.type == :assign} class="font-bold text-indigo-400">→ assign</span>
            <span :if={e.type == :result and e[:ok]} class="font-bold text-emerald-400">
              ← result
            </span>
            <span :if={e.type == :result and !e[:ok]} class="font-bold text-rose-400">← timeout</span>
            <span class="text-emerald-300">{e[:to] || e[:from]}</span>
            <span :if={e[:model]} class="rounded bg-indigo-500/20 px-1 text-indigo-300">
              {e[:model]}
            </span>
            <span :if={e[:backend]} class="rounded bg-zinc-700 px-1 text-zinc-400">
              {e[:backend]}
            </span>
            <span class="flex-1 truncate text-zinc-400">{e[:text]}</span>
          </div>
        </div>
      </div>

      <%!-- ★ 불량 조사 (역할별 센싱 → 종합) — 데모 클라이맥스 / RSI 1차 leg --%>
      <div :if={@snap.connected} class="mb-6 rounded-xl border-2 border-rose-200 bg-rose-50/40 p-4">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-sm font-bold text-zinc-900">🔬 불량 조사 — 역할별 센싱 → 마스터 종합</div>
            <div class="text-xs text-zinc-500">
              불량 LOT <span class="font-mono">{@lot_no}</span> — 각 엣지가 <em>자기 역할</em>을 센싱하고
              마스터가 종합합니다. <span class="text-rose-500">센싱 → 추론 → 제안 → (승인=학습신호)</span>
            </div>
          </div>
          <button
            :if={@istatus == :idle}
            phx-click="investigate"
            class="rounded-lg bg-rose-600 px-4 py-2 text-sm font-bold text-white hover:bg-rose-500"
          >
            불량 조사 →
          </button>
        </div>

        <div :if={@istatus == :running} class="mt-3 animate-pulse text-sm text-zinc-500">
          ▶ fleet 역할별 센싱 + fan-in 수집 중…
        </div>

        <div :if={@istatus in [:done, :frozen] and is_map(@inv)} class="mt-3 space-y-3">
          <%!-- 모드 배너 --%>
          <div
            :if={@inv.mode == :crystallized}
            class="rounded-lg bg-emerald-600 p-3 text-sm font-semibold text-white"
          >
            ⚡ 결정론적 재사용 — LLM 0회 · 캐시 히트 {@inv.hit_us}µs
            <span :if={@inv[:llm_ms]} class="font-normal opacity-90">
              (1회차 LLM {@inv.llm_ms}ms 대비 ~{speedup(@inv.llm_ms, @inv.hit_us)}배 · {@inv.frozen_at} 동결)
            </span>
          </div>
          <div :if={@inv.mode == :llm} class="text-xs font-semibold text-zinc-600">
            🧠 LLM 조사 (1회차, {@inv.llm_ms}ms) — Claude as compiler
          </div>

          <%!-- ① 센싱 (LLM 1회차에만; 결정화 재사용은 센싱 생략) --%>
          <div :if={@inv.mode == :llm and @inv[:observations]}>
            <div class="mb-1 text-xs font-semibold text-zinc-600">① 센싱 — 엣지 역할별 관측 (fan-in)</div>
            <div class="space-y-1">
              <div
                :for={o <- @inv.observations}
                class="flex items-start gap-2 rounded bg-white p-2 text-xs"
              >
                <span class="rounded bg-zinc-100 px-1.5 py-0.5 font-semibold text-zinc-600">
                  {o.role_task}
                </span>
                <span class="font-mono text-zinc-500">{o.agent}</span>
                <span class="text-zinc-400">→</span>
                <span class="flex-1 text-zinc-700">{result_summary(o.result)}</span>
              </div>
            </div>
          </div>

          <%!-- ② 종합 SUGGEST --%>
          <div :if={@inv[:suggest]} class="rounded-lg border border-rose-300 bg-white p-3">
            <div class="mb-2 text-xs font-semibold text-zinc-600">
              {if @inv.mode == :crystallized,
                do: "동결 룰 (결정론적)",
                else: "② 종합 — 마스터 추론 SUGGEST (제안, 판정 아님)"}
            </div>
            <div class="flex items-baseline justify-between">
              <span class="text-base font-bold text-zinc-900">{@inv.suggest["defect_type"]}</span>
              <span class="rounded bg-rose-100 px-2 py-0.5 font-mono text-xs text-rose-700">
                신뢰도 {@inv.suggest["confidence"]}
              </span>
            </div>
            <div class="mt-1 text-sm text-zinc-800">
              원인: <span class="font-semibold">{@inv.suggest["root_cause"]}</span>
            </div>
            <div class="text-xs text-zinc-500">{@inv.suggest["evidence"]}</div>
            <div class="mt-1 text-xs text-zinc-600">
              영향:
              <span :for={wo <- @inv.suggest["affected_work_orders"]} class="font-mono text-rose-600">
                {wo}
              </span>
              · 권고 <span class="font-semibold text-rose-700">{@inv.suggest["action"]}</span>
            </div>
          </div>

          <%!-- ③ 결정화 — 승인하면 룰로 동결 (LLM 1회차에만) --%>
          <div
            :if={@inv.mode == :llm && @inv[:suggest] && @istatus == :done}
            class="rounded-lg bg-zinc-900 p-3 text-xs text-zinc-300"
          >
            ③ 승인 = 결정화 — 사람이 사인한 결정을 <span class="text-emerald-300">결정론적 룰로 동결</span>합니다.
            다음 같은 패턴 불량은 <span class="text-emerald-300">LLM 0회</span>로 µs에 처리됩니다.
            <div class="mt-2">
              <button
                phx-click="freeze_decision"
                class="rounded-lg bg-emerald-500 px-3 py-1.5 font-semibold text-white hover:bg-emerald-400"
              >
                승인 → 결정 동결(스킬화)
              </button>
            </div>
          </div>

          <div :if={@istatus == :frozen} class="rounded-lg bg-emerald-50 p-3 text-xs text-emerald-800">
            ✅ 결정 동결됨 — 같은 패턴은 이제 캐시 히트. <strong>[불량 조사 →]를 다시 누르면 LLM 0회</strong>로 µs에 응답합니다.
            <div class="mt-2 flex gap-2">
              <button
                phx-click="investigate"
                class="rounded bg-rose-600 px-3 py-1 font-semibold text-white hover:bg-rose-500"
              >
                다시 조사 (캐시 히트)
              </button>
              <button phx-click="forget_skill" class="text-zinc-500 underline hover:text-zinc-700">
                동결 해제(리셋)
              </button>
            </div>
          </div>

          <button
            :if={@istatus == :done}
            phx-click="reset_inv"
            class="text-xs text-zinc-500 underline hover:text-zinc-700"
          >
            다시
          </button>
        </div>
      </div>

      <%!-- 📊 스킬 결정화 현황 — RSI 학습 루프 누적(상시 대시보드) --%>
      <div
        :if={@snap.connected}
        class="mb-6 rounded-xl border border-emerald-200 bg-emerald-50/40 p-4"
      >
        <div class="text-sm font-bold text-zinc-900">📊 스킬 결정화 현황 — RSI 학습 루프</div>
        <div class="text-xs text-zinc-500">
          승인된 결정을 <span class="font-semibold text-emerald-700">결정론적 룰로 동결</span>
          → 같은 패턴은 <span class="font-semibold text-emerald-700">LLM 0회</span>로 재사용. "LLM as compiler" 의 누적 산출.
        </div>

        <%!-- 요약 카드 --%>
        <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div class="rounded-lg bg-white p-3 text-center">
            <div class="text-2xl font-bold text-emerald-700">{@cryst.rule_count}</div>
            <div class="text-xs text-zinc-500">동결 룰</div>
          </div>
          <div class="rounded-lg bg-white p-3 text-center">
            <div class="text-2xl font-bold text-emerald-700">{commafy(@cryst.total_hits)}</div>
            <div class="text-xs text-zinc-500">LLM 절감(회)</div>
          </div>
          <div class="rounded-lg bg-white p-3 text-center">
            <div class="text-2xl font-bold text-emerald-700">{fmt_ms(@cryst.saved_ms)}</div>
            <div class="text-xs text-zinc-500">절감 시간</div>
          </div>
          <div class="rounded-lg bg-white p-3 text-center">
            <div class="text-2xl font-bold text-emerald-700">
              {if @cryst.avg_hit_us, do: "#{commafy(@cryst.avg_hit_us)}µs", else: "—"}
            </div>
            <div class="text-xs text-zinc-500">평균 캐시 히트</div>
          </div>
        </div>

        <%!-- 동결 룰 테이블 --%>
        <div :if={@cryst.rules != []} class="mt-3 overflow-x-auto">
          <table class="w-full text-left text-xs">
            <thead class="text-zinc-500">
              <tr class="border-b border-zinc-200">
                <th class="py-1 pr-3 font-medium">패턴</th>
                <th class="py-1 pr-3 font-medium">권고</th>
                <th class="py-1 pr-3 text-right font-medium">원 LLM</th>
                <th class="py-1 pr-3 text-right font-medium">재사용</th>
                <th class="py-1 pr-3 text-right font-medium">누적 절감</th>
                <th class="py-1 pr-3 font-medium">승인</th>
                <th class="py-1 font-medium">동결 시각</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @cryst.rules} class="border-b border-zinc-100">
                <td class="py-1.5 pr-3 font-mono text-zinc-800">{r.pattern}</td>
                <td class="py-1.5 pr-3">
                  <span class="rounded bg-rose-100 px-1.5 py-0.5 font-semibold text-rose-700">
                    {r.decision["action"]}
                  </span>
                </td>
                <td class="py-1.5 pr-3 text-right font-mono text-zinc-600">
                  {if r[:llm_ms], do: "#{commafy(r.llm_ms)}ms", else: "—"}
                </td>
                <td class="py-1.5 pr-3 text-right font-mono font-semibold text-emerald-700">
                  {r[:hits] || 0}회
                </td>
                <td class="py-1.5 pr-3 text-right font-mono text-emerald-700">
                  {fmt_ms((r[:hits] || 0) * (r[:llm_ms] || 0))}
                </td>
                <td class="py-1.5 pr-3 text-zinc-600">{r[:approved_by]}</td>
                <td class="py-1.5 font-mono text-zinc-400">{r[:frozen_at]}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div
          :if={@cryst.rules == []}
          class="mt-3 rounded-lg bg-white p-3 text-center text-xs text-zinc-400"
        >
          아직 동결된 룰이 없습니다. 위 <span class="font-semibold text-rose-600">불량 조사 → 승인</span>하면 여기 쌓입니다.
        </div>
      </div>

      <%!-- 분석 지시 (Approval Flow: propose → approve → fan-out → 수집) --%>
      <div :if={@snap.connected} class="mb-6 rounded-lg border border-indigo-200 bg-indigo-50/40 p-4">
        <div class="text-sm font-semibold text-zinc-800">분석 지시 — fleet fan-out</div>
        <div class="text-xs text-zinc-500">
          자유 프롬프트를 온라인 {length(@snap.agents)}개 에이전트에 동시 지시합니다(승인 후 실행).
        </div>

        <%!-- 프롬프트 입력 (idle) --%>
        <form :if={@dstatus == :idle} phx-submit="propose_dispatch" class="mt-3">
          <textarea
            name="prompt"
            rows="2"
            placeholder="에이전트에 보낼 지시를 자유롭게 입력…"
            class="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm"
          >{@prompt}</textarea>
          <div class="mt-2 flex justify-end">
            <button
              type="submit"
              disabled={@snap.agents == []}
              class="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-500 disabled:opacity-40"
            >
              분석 지시 →
            </button>
          </div>
        </form>

        <%!-- propose --%>
        <div :if={@dstatus == :proposed} class="mt-3 rounded-md border border-indigo-200 bg-white p-3">
          <p class="text-sm text-zinc-700">
            <span class="font-semibold">제안(propose)</span>
            — 이 프롬프트를 실행할까요? 지시는 <span class="font-semibold">승인 후 실행</span>됩니다(직접 실행 X).
          </p>
          <pre class="mt-2 whitespace-pre-wrap rounded bg-zinc-50 p-2 text-xs text-zinc-700">{@prompt}</pre>
          <div class="mt-1 text-xs text-zinc-500">
            대상: <span :for={a <- @snap.agents} class="font-mono">{a["name"]}</span>
          </div>
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

        <%!-- 에러 --%>
        <div
          :if={@dstatus == :dispatched and not is_map(@dispatch)}
          class="mt-3 rounded-md border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700"
        >
          지시 실패: {inspect(@dispatch)}
          <button phx-click="cancel_dispatch" class="ml-2 underline">다시</button>
        </div>

        <%!-- dispatched: fan-in 결과 --%>
        <div
          :if={@dstatus == :dispatched and is_map(@dispatch)}
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
