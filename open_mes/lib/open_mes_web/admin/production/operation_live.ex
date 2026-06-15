defmodule OpenMesWeb.Admin.Production.OperationLive do
  @moduledoc """
  생산관리 — 공정 실적 입력 LiveView.

  설계 §3.3(G2 생산관리). 특정 작업지시의 Operation 목록을 보여주고,
    - 공정 추가(create_operation, pending)
    - 공정 상태 전이(ready/start/pause/complete/skip — 허용 전이만 버튼 노출)
    - ProductionResult 입력(양품/불량/작업자/설비) — append-only
    - 불량수량 > 0 입력 시 DefectRecord 연결(불량유형/수량)

  모든 쓰기는 `OpenMes.Production` 컨텍스트 경유(AuditLog/Outbox/상태머신 내장).
  ProductionResult/DefectRecord 는 정정 이력(append-only): 수정이 아니라 추가만.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.Production
  alias OpenMes.Production.{Operation, OperationStateMachine}

  @impl true
  def mount(%{"id" => work_order_id}, _session, socket) do
    case Production.fetch_work_order(work_order_id) do
      {:ok, wo} ->
        workers = MasterData.list_workers(%{"active" => "true"})
        equipment = MasterData.list_equipment(%{"active" => "true"})
        processes = MasterData.list_processes(%{"active" => "true"})

        {:ok,
         socket
         |> assign(
           page_title: "공정 실적 입력",
           work_order: wo,
           item: MasterData.get_item(wo.item_id),
           worker_options: Enum.map(workers, &{"#{&1.worker_code} · #{&1.name}", &1.id}),
           equipment_options: Enum.map(equipment, &{"#{&1.equipment_code} · #{&1.name}", &1.id}),
           process_options: Enum.map(processes, &{"#{&1.process_code} · #{&1.name}", &1.id}),
           process_lookup: Map.new(processes, &{&1.id, &1}),
           selected_operation: nil,
           result_form: nil,
           defect_form: nil
         )
         |> load_operations()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "존재하지 않는 작업지시입니다")
         |> push_navigate(to: ~p"/admin/work-orders")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── 공정 추가 ─────────────────────────────────────────────────────
  @impl true
  def handle_event("add_operation", %{"operation" => params}, socket) do
    actor = socket.assigns.current_actor
    wo = socket.assigns.work_order
    attrs = Map.put(params, "work_order_id", wo.id)

    case Production.create_operation(attrs, actor) do
      {:ok, _op} ->
        {:noreply,
         socket
         |> put_flash(:info, "공정을 추가했습니다")
         |> assign(:op_form, to_form(Operation.create_changeset(%Operation{}, %{})))
         |> load_operations()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :op_form, to_form(cs))}
    end
  end

  # ── 공정 상태 전이 ─────────────────────────────────────────────────
  def handle_event("op_transition", %{"id" => id, "to" => to}, socket) do
    actor = socket.assigns.current_actor

    result =
      case to do
        "ready" -> Production.ready_operation(id, actor)
        "running" -> Production.start_operation(id, actor)
        "paused" -> Production.pause_operation(id, actor)
        "completed" -> Production.complete_operation(id, actor)
        "skipped" -> Production.skip_operation(id, actor)
        _ -> {:error, :invalid_transition}
      end

    case result do
      {:ok, _op} ->
        {:noreply,
         socket
         |> put_flash(:info, "공정 상태를 변경했습니다")
         |> load_operations()
         |> refresh_selected()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "공정 상태 전이에 실패했습니다")}
    end
  end

  # ── 실적 입력 패널 ─────────────────────────────────────────────────
  def handle_event("select_operation", %{"id" => id}, socket) do
    case Production.fetch_operation(id) do
      {:ok, op} ->
        {:noreply,
         socket
         |> assign(:selected_operation, op)
         |> assign(:results, Production.list_production_results(op.id))
         |> assign(:result_form, blank_result_form())
         |> assign(:defect_form, nil)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "존재하지 않는 공정입니다")}
    end
  end

  def handle_event("save_result", %{"result" => params}, socket) do
    actor = socket.assigns.current_actor
    op = socket.assigns.selected_operation
    attrs = Map.put(params, "operation_id", op.id)

    case Production.create_production_result(attrs, actor) do
      {:ok, result} ->
        # 불량수량 > 0 이면 DefectRecord 입력 폼을 띄워 불량유형/수량을 연결한다.
        defect_qty = parse_decimal(params["defect_quantity"])

        socket =
          socket
          |> put_flash(:info, "실적을 등록했습니다")
          |> assign(:results, Production.list_production_results(op.id))
          |> assign(:result_form, blank_result_form())

        socket =
          if defect_qty != nil and Decimal.gt?(defect_qty, 0) do
            assign(socket, :defect_form, defect_form_for(result.id, defect_qty))
          else
            assign(socket, :defect_form, nil)
          end

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :result_form, to_form(cs, as: :result))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "실적 등록에 실패했습니다")}
    end
  end

  def handle_event("save_defect", %{"defect" => params}, socket) do
    actor = socket.assigns.current_actor
    op = socket.assigns.selected_operation

    case Production.record_defect(params, actor) do
      {:ok, _defect} ->
        {:noreply,
         socket
         |> put_flash(:info, "불량을 기록했습니다")
         |> assign(:results, Production.list_production_results(op.id))
         |> assign(:defect_form, nil)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :defect_form, to_form(cs, as: :defect))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "불량 기록에 실패했습니다")}
    end
  end

  def handle_event("cancel_defect", _params, socket) do
    {:noreply, assign(socket, :defect_form, nil)}
  end

  defp load_operations(socket) do
    ops = Production.list_operations(socket.assigns.work_order.id)

    socket
    |> assign(:operations, ops)
    |> assign_new(:op_form, fn -> to_form(Operation.create_changeset(%Operation{}, %{})) end)
  end

  defp refresh_selected(%{assigns: %{selected_operation: nil}} = socket), do: socket

  defp refresh_selected(%{assigns: %{selected_operation: op}} = socket) do
    case Production.get_operation(op.id) do
      nil -> socket
      fresh -> assign(socket, :selected_operation, fresh)
    end
  end

  defp blank_result_form do
    to_form(%{
      "good_quantity" => "0",
      "defect_quantity" => "0",
      "worker_id" => "",
      "equipment_id" => ""
    }, as: :result)
  end

  defp defect_form_for(production_result_id, default_qty) do
    to_form(%{
      "production_result_id" => production_result_id,
      "defect_code" => "",
      "quantity" => Decimal.to_string(default_qty),
      "note" => ""
    }, as: :defect)
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {dec, _} -> dec
      :error -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header
        title={"공정 실적 — #{@work_order.work_order_no}"}
        subtitle={"품목: #{if @item, do: "#{@item.item_code} · #{@item.name}", else: @work_order.item_id} · 작업지시 상태: #{@work_order.status}"}
      >
        <:actions>
          <.link patch={~p"/admin/work-orders/#{@work_order.id}"}>
            <.button class="bg-zinc-100 text-zinc-700 hover:bg-zinc-200">작업지시 상세</.button>
          </.link>
        </:actions>
      </.page_header>

      <div class="grid gap-6 lg:grid-cols-2">
        <%!-- 공정 목록 + 상태 전이 --%>
        <div class="space-y-4">
          <div class="rounded-lg border border-zinc-200 p-5">
            <h2 class="mb-3 text-sm font-semibold text-zinc-900">공정 추가</h2>
            <.simple_form for={@op_form} phx-submit="add_operation">
              <div class="flex flex-wrap items-end gap-3">
                <div class="grow">
                  <.input
                    field={@op_form[:process_id]}
                    type="select"
                    label="공정"
                    options={@process_options}
                    prompt="공정 선택"
                  />
                </div>
                <div class="w-24">
                  <.input field={@op_form[:sequence]} type="number" label="순서" />
                </div>
              </div>
              <:actions>
                <.button phx-disable-with="추가 중...">공정 추가</.button>
              </:actions>
            </.simple_form>
          </div>

          <div class="rounded-lg border border-zinc-200 p-5">
            <h2 class="mb-3 text-sm font-semibold text-zinc-900">공정 목록</h2>
            <.empty_state :if={@operations == []} message="공정이 없습니다. 위에서 공정을 추가하세요." />
            <ul :if={@operations != []} class="divide-y divide-zinc-100">
              <li :for={op <- @operations} class="py-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="flex items-center gap-3">
                    <span class="text-sm font-medium text-zinc-900">#{op.sequence}</span>
                    <span class="text-sm text-zinc-500">{process_label(@process_lookup, op.process_id)}</span>
                    <.status_badge status={op.status} />
                  </div>
                  <button
                    type="button"
                    phx-click="select_operation"
                    phx-value-id={op.id}
                    class={[
                      "rounded-md px-2.5 py-1 text-xs font-medium",
                      @selected_operation && @selected_operation.id == op.id &&
                        "bg-indigo-600 text-white",
                      !(@selected_operation && @selected_operation.id == op.id) &&
                        "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                    ]}
                  >
                    실적 입력
                  </button>
                </div>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <button
                    :for={to <- op_transitions(op.status)}
                    type="button"
                    phx-click="op_transition"
                    phx-value-id={op.id}
                    phx-value-to={to}
                    data-confirm={"공정을 '#{op_status_label(to)}' (으)로 변경하시겠습니까?"}
                    class="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-700 hover:bg-zinc-50"
                  >
                    {op_status_label(to)}
                  </button>
                  <span :if={op_transitions(op.status) == []} class="text-xs text-zinc-400">
                    종료 상태
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </div>

        <%!-- 실적 입력 패널 --%>
        <div class="space-y-4">
          <div :if={@selected_operation == nil} class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
            좌측에서 공정의 '실적 입력' 을 선택하세요.
          </div>

          <div :if={@selected_operation} class="rounded-lg border border-zinc-200 p-5">
            <h2 class="mb-1 text-sm font-semibold text-zinc-900">
              공정 #{@selected_operation.sequence} 실적 입력
            </h2>
            <p class="mb-3 text-xs text-zinc-500">
              실적은 정정 이력(append-only)입니다. 잘못 입력 시 수정이 아니라 새 레코드로 정정합니다.
            </p>

            <.simple_form :if={@defect_form == nil} for={@result_form} phx-submit="save_result">
              <div class="grid grid-cols-2 gap-3">
                <.input field={@result_form[:good_quantity]} type="number" step="any" label="양품수량" />
                <.input field={@result_form[:defect_quantity]} type="number" step="any" label="불량수량" />
              </div>
              <.input field={@result_form[:worker_id]} type="select" label="작업자" options={@worker_options} prompt="선택 안함" />
              <.input field={@result_form[:equipment_id]} type="select" label="설비" options={@equipment_options} prompt="선택 안함" />
              <:actions>
                <.button phx-disable-with="등록 중...">실적 등록</.button>
              </:actions>
            </.simple_form>

            <%!-- 불량수량 > 0 입력 시 DefectRecord 연결 폼 --%>
            <div :if={@defect_form} class="rounded-lg border border-amber-200 bg-amber-50 p-4">
              <h3 class="mb-2 text-sm font-semibold text-amber-800">불량 상세 기록</h3>
              <p class="mb-3 text-xs text-amber-700">
                불량수량이 입력되었습니다. 불량유형과 수량을 기록하세요(DefectRecord 연결).
              </p>
              <.simple_form for={@defect_form} phx-submit="save_defect">
                <input type="hidden" name="defect[production_result_id]" value={@defect_form[:production_result_id].value} />
                <.input field={@defect_form[:defect_code]} label="불량유형 코드" />
                <.input field={@defect_form[:quantity]} type="number" step="any" label="불량수량" />
                <.input field={@defect_form[:note]} type="textarea" label="비고" />
                <:actions>
                  <.button phx-disable-with="기록 중...">불량 기록</.button>
                  <button type="button" phx-click="cancel_defect" class="text-sm text-zinc-500 hover:underline">
                    건너뛰기
                  </button>
                </:actions>
              </.simple_form>
            </div>

            <div class="mt-5">
              <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-400">실적 이력</h3>
              <.empty_state :if={@results == []} message="등록된 실적이 없습니다." />
              <.table :if={@results != []} id="results" rows={@results}>
                <:col :let={r} label="양품">{r.good_quantity}</:col>
                <:col :let={r} label="불량">{r.defect_quantity}</:col>
                <:col :let={r} label="등록시각">{Calendar.strftime(r.inserted_at, "%m-%d %H:%M")}</:col>
              </.table>
            </div>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  # 현재 상태에서 허용된 전이만 반환(상태머신 위반 버튼 비노출).
  defp op_transitions(status), do: OperationStateMachine.allowed_from(status)

  defp process_label(lookup, process_id) do
    case Map.get(lookup, process_id) do
      nil -> "공정 #{String.slice(to_string(process_id), 0, 8)}"
      p -> "#{p.process_code} · #{p.name}"
    end
  end

  defp op_status_label("pending"), do: "대기"
  defp op_status_label("ready"), do: "준비"
  defp op_status_label("running"), do: "진행"
  defp op_status_label("paused"), do: "일시정지"
  defp op_status_label("completed"), do: "완료"
  defp op_status_label("skipped"), do: "건너뜀"
  defp op_status_label(other), do: other
end
