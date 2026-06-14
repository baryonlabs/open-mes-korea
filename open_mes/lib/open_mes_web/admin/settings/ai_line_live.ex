defmodule OpenMesWeb.Admin.Settings.AiLineLive do
  @moduledoc """
  설정 — AI 자연어 생산라인 구성(propose→승인→실행) LiveView(설계 23번 §A.7).

  흐름: 라인 선택 → 자연어 입력 → AI 제안(diff 미리보기 + 근거 referenced_resources)
       → 승인하고 적용 / 거부. 모든 쓰기는 OpenMes.Ai 컨텍스트 경유(AuditLog/Outbox/상태머신).
       LiveView 는 Repo 를 직접 호출하지 않는다.

  안전 UI 규칙: 제안 패널은 항상 근거를 diff 와 함께 노출. AI 가 "적용됨"으로 보이지 않게
       항상 "제안"과 "승인 후 적용"을 구분한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Ai
  alias OpenMes.ProductionLine

  @impl true
  def mount(_params, _session, socket) do
    lines = ProductionLine.list_lines(active: true)
    selected = List.first(lines)

    {:ok,
     socket
     |> assign(page_title: "AI 라인 구성")
     |> assign(lines: lines)
     |> assign(selected_line_id: selected && selected.id)
     |> assign(prompt: "")
     |> assign(proposal: nil)
     |> assign(error: nil)
     |> load_history()}
  end

  @impl true
  def handle_event("select_line", %{"line_id" => line_id}, socket) do
    {:noreply,
     socket
     |> assign(selected_line_id: line_id, proposal: nil, error: nil)
     |> load_history()}
  end

  def handle_event("propose", %{"prompt" => prompt}, socket) do
    line_id = socket.assigns.selected_line_id
    actor = %{actor_id: socket.assigns.current_actor, role: socket.assigns.current_role}

    cond do
      is_nil(line_id) ->
        {:noreply, assign(socket, error: "먼저 라인을 선택하세요.")}

      String.trim(prompt) == "" ->
        {:noreply, assign(socket, error: "변경 지시를 입력하세요.")}

      true ->
        case Ai.propose_line_config(line_id, prompt, actor) do
          {:ok, interaction} ->
            {:noreply,
             socket
             |> assign(proposal: interaction, prompt: prompt, error: nil)
             |> load_history()}

          {:error, :unauthorized} ->
            {:noreply, assign(socket, error: "AI 라인 구성 권한이 없습니다.")}

          {:error, reason} ->
            {:noreply, assign(socket, error: "AI 제안 생성 실패: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("approve_apply", %{"id" => id}, socket) do
    reviewer = %{actor_id: socket.assigns.current_actor, role: socket.assigns.current_role}

    with {:ok, _} <- Ai.approve_proposal(id, reviewer),
         {:ok, _} <- Ai.apply_proposal(id, reviewer) do
      {:noreply,
       socket
       |> put_flash(:info, "제안을 승인하고 라인에 적용했습니다. 라인 모니터에서 확인하세요.")
       |> assign(proposal: nil)
       |> load_history()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "적용 실패(롤백됨): #{inspect(reason)}")
         |> assign(proposal: nil)
         |> load_history()}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    reviewer = %{actor_id: socket.assigns.current_actor, role: socket.assigns.current_role}

    case Ai.reject_proposal(id, "사용자 거부", reviewer) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "제안을 거부했습니다.")
         |> assign(proposal: nil)
         |> load_history()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "거부 실패: #{inspect(reason)}")}
    end
  end

  defp load_history(socket) do
    history =
      case socket.assigns[:selected_line_id] do
        nil -> []
        line_id -> Ai.list_interactions(line_id: line_id) |> Enum.take(10)
      end

    assign(socket, history: history)
  end

  defp ops_of(%{proposed_action: %{"ops" => ops}}), do: ops
  defp ops_of(_), do: []

  defp op_label(%{"op" => "add_step", "process_code" => code} = op) do
    after_part = if op["after_process_code"], do: " (#{op["after_process_code"]} 다음)", else: " (맨 뒤)"
    {"추가", "+", "text-green-700 bg-green-50", "#{code}#{after_part}"}
  end

  defp op_label(%{"op" => "remove_step", "process_code" => code}),
    do: {"삭제", "−", "text-red-700 bg-red-50", code}

  defp op_label(%{"op" => "reorder", "process_code" => code, "to" => to}),
    do: {"순서변경", "↕", "text-blue-700 bg-blue-50", "#{code} → #{to}"}

  defp op_label(op), do: {"기타", "?", "text-zinc-600 bg-zinc-50", inspect(op)}

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
        title="AI 라인 구성"
        subtitle="자연어로 라인 구성 변경을 지시하면 AI 가 변경안(diff)을 제안합니다. 승인 후에만 실제 라인에 적용됩니다."
      />

      <.empty_state
        :if={@lines == []}
        message="활성 생산라인이 없습니다. '생산라인 구성' 에서 라인을 먼저 등록하세요."
      />

      <div :if={@lines != []} class="space-y-6">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <form phx-change="select_line" class="mb-4">
            <label class="mb-1 block text-sm font-medium text-zinc-700">대상 라인</label>
            <select
              name="line_id"
              class="w-full rounded-md border-zinc-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
            >
              <option :for={line <- @lines} value={line.id} selected={line.id == @selected_line_id}>
                {line.line_code} — {line.name}
              </option>
            </select>
          </form>

          <form phx-submit="propose">
            <label class="mb-1 block text-sm font-medium text-zinc-700">변경 지시 (자연어)</label>
            <textarea
              name="prompt"
              rows="2"
              placeholder="예) 건조 다음에 예열 공정 추가, 포장을 마지막으로"
              class="w-full rounded-md border-zinc-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
            >{@prompt}</textarea>
            <div class="mt-2 flex items-center justify-between">
              <p :if={@error} class="text-sm text-red-600">{@error}</p>
              <p :if={!@error} class="text-xs text-zinc-400">
                AI 는 변경안만 제안합니다. 직접 라인을 수정하지 않습니다.
              </p>
              <.button phx-disable-with="AI 분석 중...">AI 제안 받기</.button>
            </div>
          </form>
        </div>

        <%!-- 제안 결과 패널 — diff + 근거를 항상 함께 노출(안전 UI 규칙) --%>
        <div :if={@proposal} class="rounded-lg border border-indigo-200 bg-indigo-50/30 p-4">
          <div class="mb-3 flex items-center gap-2">
            <h2 class="text-base font-semibold text-zinc-900">AI 제안 (검토 필요)</h2>
            <span class="rounded-full bg-zinc-200 px-2 py-0.5 text-xs font-medium text-zinc-700">
              {provider_badge(@proposal.provider)}
            </span>
            <.status_badge status={@proposal.approval_status} />
          </div>

          <div class="mb-4">
            <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-zinc-500">변경안 (diff)</p>
            <ul class="space-y-1">
              <li :for={op <- ops_of(@proposal)} class="flex items-center gap-2 text-sm">
                <% {kind, sym, cls, detail} = op_label(op) %>
                <span class={["inline-flex w-16 items-center justify-center rounded px-1.5 py-0.5 text-xs font-medium", cls]}>
                  {sym} {kind}
                </span>
                <span class="font-mono text-zinc-700">{detail}</span>
              </li>
            </ul>
            <p :if={ops_of(@proposal) == []} class="text-sm text-zinc-500">
              생성된 변경안이 없습니다(아래 근거 설명 참고).
            </p>
          </div>

          <div class="mb-4 rounded-md border border-zinc-200 bg-white p-3">
            <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-zinc-500">근거 (AI 가 참조한 데이터)</p>
            <p class="text-sm text-zinc-700">{@proposal.response_summary}</p>
            <dl class="mt-2 grid grid-cols-2 gap-1 text-xs text-zinc-500">
              <div :for={{k, v} <- ref_rows(@proposal)}>
                <dt class="inline font-medium">{k}:</dt>
                <dd class="inline">{v}</dd>
              </div>
            </dl>
          </div>

          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="approve_apply"
              phx-value-id={@proposal.id}
              data-confirm="이 변경안을 승인하고 라인에 적용하시겠습니까?"
              class="rounded-md bg-indigo-600 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-700"
            >
              승인하고 적용
            </button>
            <button
              type="button"
              phx-click="reject"
              phx-value-id={@proposal.id}
              class="rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-100"
            >
              거부
            </button>
          </div>
        </div>

        <%!-- 이력 목록 — 감사 가시성 --%>
        <div>
          <h2 class="mb-2 text-sm font-semibold text-zinc-700">최근 AI 상호작용 이력</h2>
          <.empty_state :if={@history == []} message="이 라인의 AI 상호작용 이력이 없습니다." />
          <.table :if={@history != []} id="ai-history" rows={@history}>
            <:col :let={i} label="상태"><.status_badge status={i.approval_status} /></:col>
            <:col :let={i} label="요청자">{i.actor_id}</:col>
            <:col :let={i} label="지시">{String.slice(i.prompt, 0, 40)}</:col>
            <:col :let={i} label="Provider">{provider_badge(i.provider)}</:col>
            <:col :let={i} label="시각">{Calendar.strftime(i.inserted_at, "%m-%d %H:%M")}</:col>
          </.table>
        </div>
      </div>
    </.admin_shell>
    """
  end

  defp provider_badge("mock"), do: "Mock 파서"
  defp provider_badge("claude"), do: "Claude"
  defp provider_badge(other), do: other || "—"

  defp ref_rows(%{referenced_resources: ref}) when is_map(ref) do
    [
      {"현재 단계 수", Map.get(ref, "current_step_count", "—")},
      {"선택 가능 공정", Map.get(ref, "available_process_count", "—")},
      {"선택 가능 설비", Map.get(ref, "available_equipment_count", "—")},
      {"파서", Map.get(ref, "parser", "—")}
    ]
  end

  defp ref_rows(_), do: []
end
