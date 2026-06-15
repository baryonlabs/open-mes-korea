defmodule OpenMesWeb.Admin.Production.WorkOrderLive do
  @moduledoc """
  생산관리 — 작업지시(WorkOrder) 관리 LiveView.

  설계 §3.3(G2 생산관리). 모든 쓰기는 `OpenMes.Production` 컨텍스트 경유
  (AuditLog/Outbox/상태머신 내장). LiveView 는 Repo 를 직접 쓰지 않는다.

  live_action:
    - :index — 목록(상태/품목/납기 필터)
    - :new   — 신규 작업지시 생성(품목 드롭다운, 계획수량/납기)
    - :show  — 상세 + 상태 전이 버튼(허용 전이만 노출)

  상태 전이는 WorkOrderStateMachine.allowed_from/1 으로 허용 전이만 버튼 노출하고,
  컨텍스트의 동사형 함수(release/start/complete/cancel)를 호출한다.
  멱등/불법 전이는 컨텍스트가 거부하지만 UI 에서도 막는다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.Production
  alias OpenMes.Production.{WorkOrder, WorkOrderStateMachine}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "작업지시 관리",
       status_filter: "",
       item_filter: "",
       due_filter: ""
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:form, nil)
    |> assign(:work_order, nil)
    |> load_work_orders()
    |> assign_items()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:form, to_form(WorkOrder.create_changeset(%WorkOrder{}, %{})))
    |> assign(:work_order, nil)
    |> load_work_orders()
    |> assign_items()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Production.fetch_work_order(id) do
      {:ok, wo} ->
        socket
        |> assign(:form, nil)
        |> assign(:work_order, wo)
        |> assign(:item, MasterData.get_item(wo.item_id))
        |> assign(:operations, Production.list_operations(wo.id))
        |> assign_items()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 작업지시입니다")
        |> push_navigate(to: ~p"/admin/work-orders")
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status, "item_id" => item_id, "due_date" => due}, socket) do
    {:noreply,
     socket
     |> assign(status_filter: status, item_filter: item_id, due_filter: due)
     |> load_work_orders()}
  end

  def handle_event("validate", %{"work_order" => params}, socket) do
    changeset =
      %WorkOrder{}
      |> WorkOrder.create_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"work_order" => params}, socket) do
    actor = socket.assigns.current_actor

    case Production.create_work_order(params, actor) do
      {:ok, _wo} ->
        {:noreply,
         socket
         |> put_flash(:info, "작업지시를 생성했습니다")
         |> push_patch(to: ~p"/admin/work-orders")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  # 상태 전이 — 허용 전이만 버튼이 노출되므로 to 는 항상 유효 후보.
  # 컨텍스트가 최종 방어선(불법/멱등 거부).
  def handle_event("transition", %{"to" => to}, socket) do
    actor = socket.assigns.current_actor
    wo = socket.assigns.work_order

    result =
      case to do
        "released" -> Production.release_work_order(wo.id, actor)
        "in_progress" -> Production.start_work_order(wo.id, actor)
        "completed" -> Production.complete_work_order(wo.id, actor)
        "cancelled" -> Production.cancel_work_order(wo.id, actor)
        _ -> {:error, :invalid_transition}
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "상태를 '#{status_label(updated.status)}' (으)로 변경했습니다")
         |> assign(:work_order, updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "상태 전이에 실패했습니다")}
    end
  end

  defp load_work_orders(socket) do
    filters =
      %{}
      |> maybe_put("status", socket.assigns.status_filter)
      |> maybe_put("item_id", socket.assigns.item_filter)
      |> maybe_put("due_date", socket.assigns.due_filter)

    assign(socket, :work_orders, Production.list_work_orders(filters))
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp assign_items(socket) do
    items = MasterData.list_items(%{"active" => "true"})

    socket
    |> assign(:items, items)
    |> assign(:item_options, Enum.map(items, &{"#{&1.item_code} · #{&1.name}", &1.id}))
    |> assign(:item_lookup, Map.new(items, &{&1.id, &1}))
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header
        title={"작업지시 #{@work_order.work_order_no}"}
        subtitle="상세 · 상태 전이"
      >
        <:actions>
          <.link patch={~p"/admin/work-orders"}>
            <.button class="bg-zinc-100 text-zinc-700 hover:bg-zinc-200">목록</.button>
          </.link>
        </:actions>
      </.page_header>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="lg:col-span-2 space-y-6">
          <div class="rounded-lg border border-zinc-200 p-5">
            <dl class="grid grid-cols-2 gap-x-6 gap-y-4 text-sm">
              <div>
                <dt class="text-xs font-medium text-zinc-500">작업지시번호</dt>
                <dd class="mt-0.5 font-medium text-zinc-900">{@work_order.work_order_no}</dd>
              </div>
              <div>
                <dt class="text-xs font-medium text-zinc-500">상태</dt>
                <dd class="mt-0.5"><.status_badge status={@work_order.status} /></dd>
              </div>
              <div>
                <dt class="text-xs font-medium text-zinc-500">품목</dt>
                <dd class="mt-0.5 text-zinc-900">
                  {if @item, do: "#{@item.item_code} · #{@item.name}", else: @work_order.item_id}
                </dd>
              </div>
              <div>
                <dt class="text-xs font-medium text-zinc-500">계획수량</dt>
                <dd class="mt-0.5 text-zinc-900">{@work_order.planned_quantity}</dd>
              </div>
              <div>
                <dt class="text-xs font-medium text-zinc-500">납기</dt>
                <dd class="mt-0.5 text-zinc-900">{@work_order.due_date || "-"}</dd>
              </div>
            </dl>
          </div>

          <div class="rounded-lg border border-zinc-200 p-5">
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-sm font-semibold text-zinc-900">공정 목록</h2>
              <.link
                navigate={~p"/admin/work-orders/#{@work_order.id}/operations"}
                class="text-sm text-indigo-600 hover:underline"
              >
                공정 실적 입력 →
              </.link>
            </div>
            <.empty_state :if={@operations == []} message="등록된 공정이 없습니다. '공정 실적 입력' 에서 추가하세요." />
            <.table :if={@operations != []} id="wo-operations" rows={@operations}>
              <:col :let={op} label="순서">{op.sequence}</:col>
              <:col :let={op} label="상태"><.status_badge status={op.status} /></:col>
            </.table>
          </div>
        </div>

        <div class="space-y-3">
          <div class="rounded-lg border border-zinc-200 p-5">
            <h2 class="mb-3 text-sm font-semibold text-zinc-900">상태 전이</h2>
            <p :if={transitions(@work_order.status) == []} class="text-sm text-zinc-500">
              종료 상태입니다. 가능한 전이가 없습니다.
            </p>
            <div class="flex flex-col gap-2">
              <button
                :for={to <- transitions(@work_order.status)}
                type="button"
                phx-click="transition"
                phx-value-to={to}
                data-confirm={"'#{status_label(to)}' (으)로 변경하시겠습니까?"}
                class={transition_btn_class(to)}
              >
                {transition_label(to)}
              </button>
            </div>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="작업지시 관리" subtitle="작업지시 목록 · 생성 · 상태 전이">
        <:actions>
          <.link patch={~p"/admin/work-orders/new"}>
            <.button>신규 작업지시</.button>
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="filter" phx-submit="filter" class="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-500">상태</label>
          <select name="status" class="mt-1 rounded-lg border-zinc-300 text-sm">
            <option value="" selected={@status_filter == ""}>전체</option>
            <option :for={s <- WorkOrderStateMachine.statuses()} value={s} selected={@status_filter == s}>
              {status_label(s)}
            </option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">품목</label>
          <select name="item_id" class="mt-1 rounded-lg border-zinc-300 text-sm">
            <option value="" selected={@item_filter == ""}>전체</option>
            <option :for={{label, id} <- @item_options} value={id} selected={@item_filter == id}>
              {label}
            </option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">납기</label>
          <input type="date" name="due_date" value={@due_filter} class="mt-1 rounded-lg border-zinc-300 text-sm" />
        </div>
      </form>

      <.empty_state :if={@work_orders == []} message="작업지시가 없습니다. '신규 작업지시' 로 추가하세요." />

      <.table :if={@work_orders != []} id="work-orders" rows={@work_orders}>
        <:col :let={wo} label="작업지시번호">{wo.work_order_no}</:col>
        <:col :let={wo} label="품목">{item_label(@item_lookup, wo.item_id)}</:col>
        <:col :let={wo} label="계획수량">{wo.planned_quantity}</:col>
        <:col :let={wo} label="납기">{wo.due_date || "-"}</:col>
        <:col :let={wo} label="상태"><.status_badge status={wo.status} /></:col>
        <:action :let={wo}>
          <.link navigate={~p"/admin/work-orders/#{wo.id}"} class="text-indigo-600 hover:underline">
            상세
          </.link>
        </:action>
        <:action :let={wo}>
          <.link
            navigate={~p"/admin/work-orders/#{wo.id}/operations"}
            class="text-zinc-500 hover:underline"
          >
            공정실적
          </.link>
        </:action>
      </.table>

      <.modal :if={@form} id="wo-modal" show on_cancel={JS.patch(~p"/admin/work-orders")}>
        <.header>신규 작업지시</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:work_order_no]} label="작업지시번호" />
          <.input field={@form[:item_id]} type="select" label="품목" options={@item_options} prompt="품목 선택" />
          <.input field={@form[:planned_quantity]} type="number" step="any" label="계획수량" />
          <.input field={@form[:due_date]} type="date" label="납기" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end

  # 현재 상태에서 허용된 전이만 반환(상태머신 위반 버튼 비노출).
  defp transitions(status), do: WorkOrderStateMachine.allowed_from(status)

  defp item_label(lookup, item_id) do
    case Map.get(lookup, item_id) do
      nil -> item_id
      item -> "#{item.item_code} · #{item.name}"
    end
  end

  defp status_label("draft"), do: "작성중"
  defp status_label("released"), do: "지시"
  defp status_label("in_progress"), do: "진행중"
  defp status_label("completed"), do: "완료"
  defp status_label("cancelled"), do: "취소"
  defp status_label(other), do: other

  defp transition_label("released"), do: "지시 (release)"
  defp transition_label("in_progress"), do: "착수 (start)"
  defp transition_label("completed"), do: "완료 (complete)"
  defp transition_label("cancelled"), do: "취소 (cancel)"
  defp transition_label(other), do: other

  defp transition_btn_class("cancelled"),
    do: "rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-100"

  defp transition_btn_class(_),
    do: "rounded-lg bg-indigo-600 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-700"
end
