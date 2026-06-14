defmodule OpenMesWeb.Shopfloor.ScanLive do
  @moduledoc """
  현장 — LOT 스캔/투입 LiveView (설계 §3.3 G4).

  LOT 번호 입력(바코드 스캐너 = 키보드 입력으로 대체)으로 투입 LOT 을 조회하고,
  공정(Operation)에 수량만큼 투입(소비)한다. 소비는 `OpenMes.Lots.consume_lot/4` 경유
  (LotConsumption + 상태전이 + AuditLog/Outbox). 초과소비는 컨텍스트가 차단하고 UI 도 잔량 표시.

  operation_id 쿼리 파라미터로 작업 상세에서 진입 시 공정을 선점할 수 있다.
  """
  use OpenMesWeb.Shopfloor.ShopfloorLive

  alias OpenMes.Lots
  alias OpenMes.Production

  @impl true
  def mount(params, _session, socket) do
    operations =
      Production.list_work_orders(%{})
      |> Enum.filter(&(&1.status in ["released", "in_progress"]))
      |> Enum.flat_map(fn wo ->
        wo.id
        |> Production.list_operations()
        |> Enum.reject(&(&1.status in ["completed", "skipped"]))
        |> Enum.map(fn op -> {"#{wo.work_order_no} · 공정#{op.sequence}", op.id} end)
      end)

    {:ok,
     assign(socket,
       page_title: "LOT 스캔",
       operation_options: operations,
       operation_id: params["operation_id"] || "",
       scanned_lot: nil,
       lot_no: ""
     )}
  end

  @impl true
  def handle_event("scan", %{"lot_no" => lot_no}, socket) do
    case Lots.get_lot_by_no(String.trim(lot_no)) do
      nil ->
        {:noreply,
         socket
         |> assign(scanned_lot: nil, lot_no: lot_no)
         |> put_flash(:error, "해당 LOT 번호를 찾을 수 없습니다")}

      lot ->
        {:noreply, assign(socket, scanned_lot: lot, lot_no: lot.lot_no)}
    end
  end

  def handle_event("select_operation", %{"operation_id" => op_id}, socket) do
    {:noreply, assign(socket, :operation_id, op_id)}
  end

  def handle_event("consume", %{"quantity" => quantity}, socket) do
    actor = socket.assigns.current_actor
    lot = socket.assigns.scanned_lot
    op_id = socket.assigns.operation_id

    cond do
      lot == nil ->
        {:noreply, put_flash(socket, :error, "먼저 LOT 을 스캔하세요")}

      op_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "투입할 공정을 선택하세요")}

      true ->
        case Lots.consume_lot(op_id, lot.id, quantity, actor) do
          {:ok, _consumption} ->
            fresh = Lots.get_lot(lot.id)

            {:noreply,
             socket
             |> put_flash(:info, "LOT 을 투입했습니다")
             |> assign(:scanned_lot, fresh)}

          {:error, :insufficient_lot_quantity} ->
            {:noreply, put_flash(socket, :error, "잔량을 초과하여 투입할 수 없습니다")}

          {:error, :lot_not_consumable} ->
            {:noreply, put_flash(socket, :error, "소비할 수 없는 LOT 상태입니다")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "투입에 실패했습니다")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shopfloor_shell title="LOT 스캔" current_actor={@current_actor} current_role={@current_role} back={~p"/shopfloor"}>
      <div class="rounded-2xl bg-white p-6 shadow-sm">
        <label class="mb-2 block text-base font-semibold text-zinc-700">LOT 번호 스캔/입력</label>
        <form phx-submit="scan" class="flex gap-3">
          <input
            type="text"
            name="lot_no"
            value={@lot_no}
            autofocus
            placeholder="바코드 스캔 또는 LOT 번호 입력"
            class="h-16 grow rounded-xl border-zinc-300 text-2xl font-mono"
          />
          <.big_button color="primary" type="submit" class="!w-40">조회</.big_button>
        </form>
      </div>

      <div :if={@scanned_lot} class="mt-6 rounded-2xl bg-white p-6 shadow-sm">
        <div class="flex items-center justify-between">
          <p class="font-mono text-2xl font-bold text-zinc-900">{@scanned_lot.lot_no}</p>
          <.big_status_badge status={@scanned_lot.status} />
        </div>
        <p class="mt-2 text-xl text-zinc-700">잔량 <span class="font-bold">{@scanned_lot.quantity}</span></p>

        <form phx-change="select_operation" class="mt-5">
          <label class="mb-1 block text-base font-semibold text-zinc-700">투입 공정</label>
          <select name="operation_id" class="h-14 w-full rounded-xl border-zinc-300 text-lg">
            <option value="">공정 선택</option>
            <option :for={{label, id} <- @operation_options} value={id} selected={@operation_id == id}>{label}</option>
          </select>
        </form>

        <form phx-submit="consume" class="mt-4">
          <label class="mb-1 block text-base font-semibold text-zinc-700">투입 수량</label>
          <input
            type="number"
            name="quantity"
            inputmode="decimal"
            step="any"
            value="0"
            class="h-16 w-full rounded-xl border-indigo-300 text-center text-3xl font-bold"
          />
          <.big_button color="start" type="submit" class="mt-4" phx-disable-with="투입 중...">투입 기록</.big_button>
        </form>
      </div>

      <.sf_empty :if={@scanned_lot == nil} message="LOT 을 스캔하면 잔량과 투입 화면이 표시됩니다." />
    </.shopfloor_shell>
    """
  end
end
