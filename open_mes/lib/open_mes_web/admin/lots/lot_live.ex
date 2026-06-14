defmodule OpenMesWeb.Admin.Lots.LotLive do
  @moduledoc """
  LOT 추적 — 자재/제품 LOT 관리 LiveView (설계 §3.3 G3).

  화면 기능:
    - 자재 LOT 등록(receive_lot) — 품목 드롭다운, lot_no/수량/lot_type. 초기 available.
    - LOT 투입 기록(consume_lot 경유 = LotConsumption) — 공정(Operation) + 투입 LOT + 수량.
      초과소비 차단은 Lots 컨텍스트가 처리하되, UI 도 잔량을 표시한다.
    - 제품 LOT 생성(produce_lot) — Operation 연결(source_operation_id) → genealogy.
    - 계보 조회 링크(/admin/lots/:id/genealogy).

  모든 쓰기는 `OpenMes.Lots` 컨텍스트 경유(AuditLog/Outbox/상태머신/LotConsumption 내장).
  LiveView 는 Repo 를 직접 쓰지 않으며, 자재 소비는 consume_lot(LotConsumption) 만 사용한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Lots
  alias OpenMes.Lots.MaterialLot
  alias OpenMes.MasterData
  alias OpenMes.Production

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "LOT 추적", status_filter: "", panel: nil)
     |> assign_options()
     |> load_lots()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── 패널 토글 ──────────────────────────────────────────────────────
  @impl true
  def handle_event("open_panel", %{"panel" => panel}, socket) do
    {:noreply, assign(socket, :panel, panel) |> reset_forms()}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, :panel, nil)}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> load_lots()}
  end

  # ── 자재 LOT 등록 (receive_lot → available) ─────────────────────────
  def handle_event("save_receive", %{"lot" => params}, socket) do
    actor = socket.assigns.current_actor

    case Lots.receive_lot(params, actor) do
      {:ok, _lot} ->
        {:noreply,
         socket
         |> put_flash(:info, "자재 LOT 을 등록했습니다")
         |> assign(:panel, nil)
         |> load_lots()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :receive_form, to_form(cs, as: :lot))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "LOT 등록에 실패했습니다")}
    end
  end

  # ── LOT 투입 기록 (consume_lot → LotConsumption + 상태전이) ──────────
  def handle_event("save_consume", %{"consume" => params}, socket) do
    actor = socket.assigns.current_actor

    with operation_id when operation_id not in [nil, ""] <- params["operation_id"],
         input_lot_id when input_lot_id not in [nil, ""] <- params["input_lot_id"],
         qty when qty not in [nil, ""] <- params["quantity"] do
      case Lots.consume_lot(operation_id, input_lot_id, qty, actor) do
        {:ok, _consumption} ->
          {:noreply,
           socket
           |> put_flash(:info, "LOT 투입(소비)을 기록했습니다")
           |> assign(:panel, nil)
           |> load_lots()}

        {:error, :insufficient_lot_quantity} ->
          {:noreply, put_flash(socket, :error, "잔량을 초과하여 투입할 수 없습니다")}

        {:error, :lot_not_consumable} ->
          {:noreply, put_flash(socket, :error, "소비할 수 없는 LOT 상태입니다")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, :consume_form, to_form(consume_params(cs.changes), as: :consume))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "투입 기록에 실패했습니다")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "공정/LOT/수량을 모두 입력하세요")}
    end
  end

  # ── 제품 LOT 생성 (produce_lot → produced, source_operation_id) ──────
  def handle_event("save_produce", %{"produce" => params}, socket) do
    actor = socket.assigns.current_actor

    case Lots.produce_lot(params, actor) do
      {:ok, _lot} ->
        {:noreply,
         socket
         |> put_flash(:info, "제품 LOT 을 생성했습니다")
         |> assign(:panel, nil)
         |> load_lots()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :produce_form, to_form(cs, as: :produce))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "제품 LOT 생성에 실패했습니다")}
    end
  end

  # ── 데이터 로드 ────────────────────────────────────────────────────
  defp load_lots(socket) do
    filters = %{"status" => socket.assigns.status_filter}
    lots = Lots.list_lots(filters)
    assign(socket, :lots, lots)
  end

  defp assign_options(socket) do
    items = MasterData.list_items(%{"active" => "true"})
    # 진행 중 작업지시의 공정을 투입/생산 대상으로 노출(현장과 동일 컨텍스트).
    work_orders = Production.list_work_orders(%{})
    operations = Enum.flat_map(work_orders, &Production.list_operations(&1.id))
    wo_lookup = Map.new(work_orders, &{&1.id, &1})

    op_options =
      Enum.map(operations, fn op ->
        wo = Map.get(wo_lookup, op.work_order_id)
        label = "#{(wo && wo.work_order_no) || "WO"} · 공정#{op.sequence} (#{op.status})"
        {label, op.id}
      end)

    socket
    |> assign(:item_options, Enum.map(items, &{"#{&1.item_code} · #{&1.name}", &1.id}))
    |> assign(:item_lookup, Map.new(items, &{&1.id, &1}))
    |> assign(:operation_options, op_options)
  end

  defp reset_forms(socket) do
    socket
    |> assign(:receive_form, to_form(%{"lot_no" => "", "item_id" => "", "lot_type" => "raw", "quantity" => ""}, as: :lot))
    |> assign(:consume_form, to_form(%{"operation_id" => "", "input_lot_id" => "", "quantity" => ""}, as: :consume))
    |> assign(:produce_form, to_form(%{"lot_no" => "", "item_id" => "", "lot_type" => "product", "quantity" => "", "source_operation_id" => ""}, as: :produce))
  end

  defp consume_params(changes) do
    %{
      "operation_id" => Map.get(changes, :operation_id, ""),
      "input_lot_id" => Map.get(changes, :input_lot_id, ""),
      "quantity" => Map.get(changes, :quantity, "")
    }
  end

  # 소비(투입) 가능한 LOT(종료 상태 제외) — 투입 드롭다운용.
  defp consumable_lot_options(lots, lookup) do
    lots
    |> Enum.reject(&(&1.status in ["consumed", "scrapped"]))
    |> Enum.map(fn lot ->
      item = Map.get(lookup, lot.item_id)
      label = "#{lot.lot_no} · #{(item && item.item_code) || ""} · 잔량 #{lot.quantity}"
      {label, lot.id}
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :consumable_options, consumable_lot_options(assigns.lots, assigns.item_lookup))

    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="LOT 추적" subtitle="자재/제품 LOT 등록 · 투입(소비) · 제품 생성 · 계보 조회">
        <:actions>
          <.button phx-click="open_panel" phx-value-panel="receive" class="bg-zinc-900">자재 LOT 등록</.button>
          <.button phx-click="open_panel" phx-value-panel="consume" class="bg-indigo-600">LOT 투입</.button>
          <.button phx-click="open_panel" phx-value-panel="produce" class="bg-green-600">제품 LOT 생성</.button>
        </:actions>
      </.page_header>

      <%!-- 자재 LOT 등록 패널 --%>
      <div :if={@panel == "receive"} class="mb-6 rounded-lg border border-zinc-200 bg-zinc-50 p-5">
        <h2 class="mb-3 text-sm font-semibold text-zinc-900">자재 LOT 등록 (입고)</h2>
        <.simple_form for={@receive_form} phx-submit="save_receive">
          <div class="grid gap-3 sm:grid-cols-2">
            <.input field={@receive_form[:lot_no]} label="LOT 번호" />
            <.input field={@receive_form[:item_id]} type="select" label="품목" options={@item_options} prompt="품목 선택" />
            <.input field={@receive_form[:lot_type]} type="select" label="LOT 유형" options={lot_type_options()} />
            <.input field={@receive_form[:quantity]} type="number" step="any" label="수량" />
          </div>
          <:actions>
            <.button phx-disable-with="등록 중...">등록</.button>
            <button type="button" phx-click="close_panel" class="text-sm text-zinc-500 hover:underline">닫기</button>
          </:actions>
        </.simple_form>
      </div>

      <%!-- LOT 투입(소비) 패널 — consume_lot 경유 --%>
      <div :if={@panel == "consume"} class="mb-6 rounded-lg border border-indigo-200 bg-indigo-50 p-5">
        <h2 class="mb-1 text-sm font-semibold text-indigo-900">LOT 투입 (소비 → LotConsumption)</h2>
        <p class="mb-3 text-xs text-indigo-700">잔량을 초과하여 투입할 수 없습니다(초과소비 차단). 소비는 LotConsumption 으로만 기록됩니다.</p>
        <.simple_form for={@consume_form} phx-submit="save_consume">
          <.input field={@consume_form[:operation_id]} type="select" label="투입 공정(Operation)" options={@operation_options} prompt="공정 선택" />
          <.input field={@consume_form[:input_lot_id]} type="select" label="투입 LOT(잔량)" options={@consumable_options} prompt="LOT 선택" />
          <.input field={@consume_form[:quantity]} type="number" step="any" label="투입 수량" />
          <:actions>
            <.button phx-disable-with="투입 중...">투입 기록</.button>
            <button type="button" phx-click="close_panel" class="text-sm text-zinc-500 hover:underline">닫기</button>
          </:actions>
        </.simple_form>
      </div>

      <%!-- 제품 LOT 생성 패널 — produce_lot, source_operation_id 연결 --%>
      <div :if={@panel == "produce"} class="mb-6 rounded-lg border border-green-200 bg-green-50 p-5">
        <h2 class="mb-1 text-sm font-semibold text-green-900">제품 LOT 생성 (produced)</h2>
        <p class="mb-3 text-xs text-green-700">생성 공정(Operation)을 연결하면 계보(genealogy)가 추적됩니다.</p>
        <.simple_form for={@produce_form} phx-submit="save_produce">
          <div class="grid gap-3 sm:grid-cols-2">
            <.input field={@produce_form[:lot_no]} label="LOT 번호" />
            <.input field={@produce_form[:item_id]} type="select" label="품목" options={@item_options} prompt="품목 선택" />
            <.input field={@produce_form[:lot_type]} type="select" label="LOT 유형" options={lot_type_options()} />
            <.input field={@produce_form[:quantity]} type="number" step="any" label="수량" />
          </div>
          <.input field={@produce_form[:source_operation_id]} type="select" label="생성 공정(genealogy)" options={@operation_options} prompt="공정 선택" />
          <:actions>
            <.button phx-disable-with="생성 중...">제품 LOT 생성</.button>
            <button type="button" phx-click="close_panel" class="text-sm text-zinc-500 hover:underline">닫기</button>
          </:actions>
        </.simple_form>
      </div>

      <%!-- 필터 --%>
      <form phx-change="filter" class="mb-4 flex items-center gap-3">
        <label class="text-sm text-zinc-500">상태</label>
        <select name="status" class="rounded-md border-zinc-300 text-sm">
          <option value="" selected={@status_filter == ""}>전체</option>
          <option :for={s <- lot_statuses()} value={s} selected={@status_filter == s}>{lot_status_text(s)}</option>
        </select>
      </form>

      <%!-- LOT 목록 --%>
      <.empty_state :if={@lots == []} message="등록된 LOT 이 없습니다. 우측 상단에서 자재 LOT 을 등록하세요." />
      <.table :if={@lots != []} id="lots" rows={@lots}>
        <:col :let={lot} label="LOT 번호">{lot.lot_no}</:col>
        <:col :let={lot} label="품목">{item_label(@item_lookup, lot.item_id)}</:col>
        <:col :let={lot} label="유형">{lot_type_text(lot.lot_type)}</:col>
        <:col :let={lot} label="잔량">{lot.quantity}</:col>
        <:col :let={lot} label="상태"><span class="text-sm">{lot_status_text(lot.status)}</span></:col>
        <:col :let={lot} label="계보">
          <.link navigate={~p"/admin/lots/#{lot.id}/genealogy"} class="text-indigo-600 hover:underline">계보 조회</.link>
        </:col>
      </.table>
    </.admin_shell>
    """
  end

  defp lot_type_options, do: Enum.map(MaterialLot.lot_types(), &{lot_type_text(&1), &1})
  defp lot_type_text("raw"), do: "원자재"
  defp lot_type_text("semi"), do: "반제품"
  defp lot_type_text("product"), do: "제품"
  defp lot_type_text(other), do: other

  defp lot_statuses, do: ~w(available reserved produced consumed quarantined scrapped)
  defp lot_status_text("available"), do: "가용"
  defp lot_status_text("reserved"), do: "예약"
  defp lot_status_text("produced"), do: "생산됨"
  defp lot_status_text("consumed"), do: "소비완료"
  defp lot_status_text("quarantined"), do: "격리"
  defp lot_status_text("scrapped"), do: "폐기"
  defp lot_status_text(other), do: other

  defp item_label(lookup, item_id) do
    case Map.get(lookup, item_id) do
      nil -> String.slice(to_string(item_id), 0, 8)
      item -> "#{item.item_code} · #{item.name}"
    end
  end
end
