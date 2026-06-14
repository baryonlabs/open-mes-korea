defmodule OpenMesWeb.Shopfloor.ResultLive do
  @moduledoc """
  현장 — 실적 입력 LiveView (설계 §3.3 G4).

  양품/불량 수량을 큰 숫자 입력(숫자 키패드 친화 type="number")으로 빠르게 등록한다.
  실적은 append-only(정정은 새 레코드). 불량 수량 > 0 이면 DefectRecord 를 함께 기록한다.
  모든 쓰기는 `OpenMes.Production` 컨텍스트 경유(AuditLog/Outbox 내장).
  """
  use OpenMesWeb.Shopfloor.ShopfloorLive

  alias OpenMes.Production

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Production.fetch_operation(id) do
      {:ok, op} ->
        {:ok,
         socket
         |> assign(page_title: "실적 입력", op: op)
         |> reset_form()
         |> load_results()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "존재하지 않는 작업입니다")
         |> push_navigate(to: ~p"/shopfloor")}
    end
  end

  @impl true
  def handle_event("save", %{"result" => params}, socket) do
    actor = socket.assigns.current_actor
    op = socket.assigns.op
    attrs = Map.put(params, "operation_id", op.id)

    case Production.create_production_result(attrs, actor) do
      {:ok, result} ->
        defect_qty = parse_decimal(params["defect_quantity"])

        socket =
          if defect_qty && Decimal.gt?(defect_qty, 0) do
            record_defect(socket, result, params["defect_code"], defect_qty, actor)
          else
            put_flash(socket, :info, "실적을 등록했습니다")
          end

        {:noreply, socket |> reset_form() |> load_results()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :result))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "실적 등록에 실패했습니다")}
    end
  end

  defp record_defect(socket, result, defect_code, defect_qty, actor) do
    code = if defect_code in [nil, ""], do: "UNSPECIFIED", else: defect_code

    attrs = %{
      "production_result_id" => result.id,
      "defect_code" => code,
      "quantity" => Decimal.to_string(defect_qty)
    }

    case Production.record_defect(attrs, actor) do
      {:ok, _} -> put_flash(socket, :info, "실적과 불량을 등록했습니다")
      {:error, _} -> put_flash(socket, :error, "실적은 등록됐으나 불량 기록에 실패했습니다")
    end
  end

  defp reset_form(socket) do
    assign(socket, :form, to_form(%{"good_quantity" => "0", "defect_quantity" => "0", "defect_code" => ""}, as: :result))
  end

  defp load_results(socket) do
    assign(socket, :results, Production.list_production_results(socket.assigns.op.id))
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
    <.shopfloor_shell title="실적 입력" current_actor={@current_actor} current_role={@current_role} back={~p"/shopfloor/operations/#{@op.id}"}>
      <div class="rounded-2xl bg-white p-6 shadow-sm">
        <p class="mb-1 text-lg font-bold text-zinc-900">공정 {@op.sequence} 실적</p>
        <p class="mb-5 text-sm text-zinc-500">정정 이력(append-only) — 잘못 입력 시 새 실적으로 정정합니다.</p>

        <.simple_form for={@form} phx-submit="save">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="mb-1 block text-base font-semibold text-zinc-700">양품 수량</label>
              <input
                type="number"
                name="result[good_quantity]"
                value={@form[:good_quantity].value}
                inputmode="decimal"
                step="any"
                class="h-16 w-full rounded-xl border-zinc-300 text-center text-3xl font-bold"
              />
            </div>
            <div>
              <label class="mb-1 block text-base font-semibold text-zinc-700">불량 수량</label>
              <input
                type="number"
                name="result[defect_quantity]"
                value={@form[:defect_quantity].value}
                inputmode="decimal"
                step="any"
                class="h-16 w-full rounded-xl border-amber-300 text-center text-3xl font-bold text-amber-700"
              />
            </div>
          </div>
          <.input field={@form[:defect_code]} label="불량유형 코드 (불량 입력 시)" />
          <:actions>
            <.big_button color="complete" type="submit" phx-disable-with="등록 중...">실적 등록</.big_button>
          </:actions>
        </.simple_form>
      </div>

      <div class="mt-6 rounded-2xl bg-white p-5 shadow-sm">
        <h3 class="mb-3 text-base font-semibold text-zinc-700">최근 실적</h3>
        <.sf_empty :if={@results == []} message="등록된 실적이 없습니다." />
        <ul :if={@results != []} class="divide-y divide-zinc-100">
          <li :for={r <- @results} class="flex items-center justify-between py-3 text-lg">
            <span class="font-semibold text-green-700">양품 {r.good_quantity}</span>
            <span class="font-semibold text-amber-700">불량 {r.defect_quantity}</span>
            <span class="text-sm text-zinc-400">{Calendar.strftime(r.inserted_at, "%m-%d %H:%M")}</span>
          </li>
        </ul>
      </div>
    </.shopfloor_shell>
    """
  end
end
