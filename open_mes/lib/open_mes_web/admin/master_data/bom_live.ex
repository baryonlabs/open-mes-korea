defmodule OpenMesWeb.Admin.MasterData.BomLive do
  @moduledoc """
  기준정보 — BOM(BillOfMaterial) 관리 LiveView (목록 + 생성/수정).

  설계 §3.3(G1). BOM 은 부모/자식 품목(Item)을 드롭다운으로 선택한다(§3.3 — Item 참조).
  품목이 하나도 없으면 빈 상태로 등록을 막고 품목 등록을 안내한다.

  쓰기는 `OpenMes.MasterData` 컨텍스트 경유(AuditLog 내장). Repo 직접 호출 금지.
  BOM 은 active/삭제 컬럼이 없고 컨텍스트가 삭제를 제공하지 않으므로(이력 보존)
  생성/수정만 제공한다. 잘못 등록한 행 정정은 수정으로 처리한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.MasterData.BillOfMaterial

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "BOM 관리")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:form, nil) |> load_data()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:form, to_form(MasterData.change_bom(%BillOfMaterial{loss_rate: Decimal.new(0)})))
    |> assign(:editing_id, nil)
    |> load_data()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case MasterData.get_bom(id) do
      nil ->
        socket |> put_flash(:error, "존재하지 않는 BOM 입니다") |> push_patch(to: ~p"/admin/boms")

      bom ->
        socket
        |> assign(:form, to_form(MasterData.change_bom(bom)))
        |> assign(:editing_id, id)
        |> load_data()
    end
  end

  @impl true
  def handle_event("validate", %{"bill_of_material" => params}, socket) do
    changeset = BillOfMaterial.changeset(%BillOfMaterial{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"bill_of_material" => params}, socket) do
    save_row(socket, socket.assigns.editing_id, params, socket.assigns.current_actor)
  end

  defp save_row(socket, nil, params, actor) do
    case MasterData.create_bom(params, actor) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "BOM 을 생성했습니다") |> push_patch(to: ~p"/admin/boms")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_row(socket, id, params, actor) do
    case MasterData.update_bom(id, params, actor) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "BOM 을 수정했습니다") |> push_patch(to: ~p"/admin/boms")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:error, "존재하지 않는 BOM 입니다") |> push_patch(to: ~p"/admin/boms")}
    end
  end

  defp load_data(socket) do
    items = MasterData.list_items(%{"limit" => "200"})
    item_map = Map.new(items, &{&1.id, &1})

    socket
    |> assign(:rows, MasterData.list_boms(%{"limit" => "200"}))
    |> assign(:items, items)
    |> assign(:item_map, item_map)
    |> assign(:item_options, Enum.map(items, &{"#{&1.item_code} · #{&1.name}", &1.id}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="BOM 관리" subtitle="부모 품목을 구성하는 자재 명세">
        <:actions>
          <.link :if={@items != []} patch={~p"/admin/boms/new"}>
            <.button>신규 BOM</.button>
          </.link>
        </:actions>
      </.page_header>

      <.empty_state
        :if={@items == []}
        message="BOM 을 등록하려면 먼저 품목이 필요합니다."
      >
        <.link navigate={~p"/admin/items"} class="font-medium text-indigo-600 hover:underline">
          품목 관리로 이동 →
        </.link>
      </.empty_state>

      <.empty_state
        :if={@items != [] and @rows == []}
        message="등록된 BOM 이 없습니다. '신규 BOM' 으로 추가하세요."
      />

      <.table :if={@rows != []} id="boms" rows={@rows}>
        <:col :let={b} label="부모 품목">{item_label(@item_map, b.parent_item_id)}</:col>
        <:col :let={b} label="자식 품목">{item_label(@item_map, b.child_item_id)}</:col>
        <:col :let={b} label="소요량">{b.quantity}</:col>
        <:col :let={b} label="손실률">{b.loss_rate}</:col>
        <:action :let={b}>
          <.link patch={~p"/admin/boms/#{b.id}/edit"} class="text-indigo-600 hover:underline">
            수정
          </.link>
        </:action>
      </.table>

      <.modal :if={@form} id="bom-modal" show on_cancel={JS.patch(~p"/admin/boms")}>
        <.header>{if @live_action == :new, do: "신규 BOM", else: "BOM 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:parent_item_id]}
            type="select"
            label="부모 품목"
            prompt="선택하세요"
            options={@item_options}
          />
          <.input
            field={@form[:child_item_id]}
            type="select"
            label="자식 품목 (구성품)"
            prompt="선택하세요"
            options={@item_options}
          />
          <.input field={@form[:quantity]} type="number" step="any" label="소요량" />
          <.input field={@form[:loss_rate]} type="number" step="any" label="손실률 (0~1)" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end

  defp item_label(item_map, id) do
    case Map.get(item_map, id) do
      nil -> "(삭제된 품목)"
      item -> "#{item.item_code} · #{item.name}"
    end
  end
end
