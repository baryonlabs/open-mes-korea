defmodule OpenMesWeb.Shopfloor.OperationLive do
  @moduledoc """
  현장 — 작업(공정) 상세 LiveView (설계 §3.3 G4).

  대형 버튼으로 공정 상태 전이(준비/시작/일시정지/완료/건너뜀)를 수행한다.
  허용 전이만 버튼으로 노출(OperationStateMachine.allowed_from/1). 모든 전이는
  `OpenMes.Production` 컨텍스트 경유(AuditLog/Outbox/상태머신 내장).

  실적 입력(/result)·LOT 스캔(/scan) 화면으로 진입하는 큰 링크를 함께 제공한다.
  """
  use OpenMesWeb.Shopfloor.ShopfloorLive

  alias OpenMes.MasterData
  alias OpenMes.Production
  alias OpenMes.Production.OperationStateMachine

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Production.fetch_operation(id) do
      {:ok, op} ->
        {:ok, assign(socket, page_title: "작업 상세") |> assign_op(op)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "존재하지 않는 작업입니다")
         |> push_navigate(to: ~p"/shopfloor")}
    end
  end

  @impl true
  def handle_event("transition", %{"to" => to}, socket) do
    actor = socket.assigns.current_actor
    op = socket.assigns.op

    result =
      case to do
        "ready" -> Production.ready_operation(op.id, actor)
        "running" -> Production.start_operation(op.id, actor)
        "paused" -> Production.pause_operation(op.id, actor)
        "completed" -> Production.complete_operation(op.id, actor)
        "skipped" -> Production.skip_operation(op.id, actor)
        _ -> {:error, :invalid_transition}
      end

    case result do
      {:ok, fresh} ->
        {:noreply, socket |> put_flash(:info, "상태를 변경했습니다") |> assign_op(fresh)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "상태 변경에 실패했습니다")}
    end
  end

  defp assign_op(socket, op) do
    wo = Production.get_work_order(op.work_order_id)

    socket
    |> assign(:op, op)
    |> assign(:work_order, wo)
    |> assign(:item, wo && MasterData.get_item(wo.item_id))
    |> assign(:transitions, OperationStateMachine.allowed_from(op.status))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shopfloor_shell title={"공정 #{@op.sequence}"} current_actor={@current_actor} current_role={@current_role} back={~p"/shopfloor"}>
      <div class="rounded-2xl bg-white p-6 shadow-sm">
        <p class="text-base text-zinc-500">{@work_order && @work_order.work_order_no}</p>
        <div class="mt-2 flex items-center justify-between">
          <p class="text-3xl font-bold text-zinc-900">공정 {@op.sequence}</p>
          <.big_status_badge status={@op.status} />
        </div>
        <p :if={@item} class="mt-2 text-lg text-zinc-600">{@item.item_code} · {@item.name}</p>
      </div>

      <div class="mt-6 space-y-3">
        <.big_button
          :for={to <- @transitions}
          color={transition_color(to)}
          phx-click="transition"
          phx-value-to={to}
          data-confirm={"'#{transition_label(to)}' 하시겠습니까?"}
        >
          {transition_label(to)}
        </.big_button>
        <.sf_empty :if={@transitions == []} message="종료된 작업입니다." />
      </div>

      <div class="mt-8 grid grid-cols-2 gap-3">
        <.link navigate={~p"/shopfloor/operations/#{@op.id}/result"}>
          <.big_button color="default">실적 입력</.big_button>
        </.link>
        <.link navigate={~p"/shopfloor/scan?operation_id=#{@op.id}"}>
          <.big_button color="default">LOT 스캔</.big_button>
        </.link>
      </div>
    </.shopfloor_shell>
    """
  end

  defp transition_color("running"), do: "start"
  defp transition_color("completed"), do: "complete"
  defp transition_color("paused"), do: "pause"
  defp transition_color("skipped"), do: "danger"
  defp transition_color(_), do: "primary"

  defp transition_label("ready"), do: "준비"
  defp transition_label("running"), do: "작업 시작"
  defp transition_label("paused"), do: "일시정지"
  defp transition_label("completed"), do: "작업 완료"
  defp transition_label("skipped"), do: "건너뛰기"
  defp transition_label(other), do: other
end
