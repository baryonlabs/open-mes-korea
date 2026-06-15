defmodule OpenMesWeb.Admin.MasterData.RoutingLive do
  @moduledoc """
  기준정보 — 라우팅(Routing) 관리 LiveView (목록 + 생성/수정).

  설계 §3.3(G1). 라우팅은 품목(Item)·공정(Process)을 드롭다운으로 선택한다.
  품목 또는 공정이 없으면 빈 상태로 등록을 막고 등록을 안내한다.

  쓰기는 `OpenMes.MasterData` 컨텍스트 경유(AuditLog 내장). Repo 직접 호출 금지.
  Routing 은 active/삭제 컬럼이 없고 컨텍스트가 삭제를 제공하지 않으므로 생성/수정만 제공한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.MasterData.Routing

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "라우팅 관리")}
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
    |> assign(:form, to_form(MasterData.change_routing(%Routing{})))
    |> assign(:editing_id, nil)
    |> load_data()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case MasterData.get_routing(id) do
      nil ->
        socket |> put_flash(:error, "존재하지 않는 라우팅입니다") |> push_patch(to: ~p"/admin/routings")

      routing ->
        socket
        |> assign(:form, to_form(MasterData.change_routing(routing)))
        |> assign(:editing_id, id)
        |> load_data()
    end
  end

  @impl true
  def handle_event("validate", %{"routing" => params}, socket) do
    changeset = Routing.changeset(%Routing{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"routing" => params}, socket) do
    save_row(socket, socket.assigns.editing_id, params, socket.assigns.current_actor)
  end

  defp save_row(socket, nil, params, actor) do
    case MasterData.create_routing(params, actor) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "라우팅을 생성했습니다") |> push_patch(to: ~p"/admin/routings")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_row(socket, id, params, actor) do
    case MasterData.update_routing(id, params, actor) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "라우팅을 수정했습니다") |> push_patch(to: ~p"/admin/routings")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "존재하지 않는 라우팅입니다")
         |> push_patch(to: ~p"/admin/routings")}
    end
  end

  defp load_data(socket) do
    items = MasterData.list_items(%{"limit" => "200"})
    processes = MasterData.list_processes(%{"limit" => "200"})
    item_map = Map.new(items, &{&1.id, &1})
    process_map = Map.new(processes, &{&1.id, &1})

    socket
    |> assign(:rows, MasterData.list_routings(%{"limit" => "200"}))
    |> assign(:items, items)
    |> assign(:processes, processes)
    |> assign(:item_map, item_map)
    |> assign(:process_map, process_map)
    |> assign(:item_options, Enum.map(items, &{"#{&1.item_code} · #{&1.name}", &1.id}))
    |> assign(:process_options, Enum.map(processes, &{"#{&1.process_code} · #{&1.name}", &1.id}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="라우팅 관리" subtitle="품목별 공정 순서">
        <:actions>
          <.link :if={@items != [] and @processes != []} patch={~p"/admin/routings/new"}>
            <.button>신규 라우팅</.button>
          </.link>
        </:actions>
      </.page_header>

      <.empty_state
        :if={@items == [] or @processes == []}
        message="라우팅을 등록하려면 품목과 공정이 모두 필요합니다."
      >
        <div class="flex justify-center gap-4">
          <.link navigate={~p"/admin/items"} class="font-medium text-indigo-600 hover:underline">
            품목 관리 →
          </.link>
          <.link navigate={~p"/admin/processes"} class="font-medium text-indigo-600 hover:underline">
            공정 관리 →
          </.link>
        </div>
      </.empty_state>

      <.empty_state
        :if={@items != [] and @processes != [] and @rows == []}
        message="등록된 라우팅이 없습니다. '신규 라우팅' 으로 추가하세요."
      />

      <.table :if={@rows != []} id="routings" rows={@rows}>
        <:col :let={r} label="품목">{item_label(@item_map, r.item_id)}</:col>
        <:col :let={r} label="공정">{process_label(@process_map, r.process_id)}</:col>
        <:col :let={r} label="순서">{r.sequence}</:col>
        <:col :let={r} label="표준 C/T(초)">{r.standard_cycle_time}</:col>
        <:action :let={r}>
          <.link patch={~p"/admin/routings/#{r.id}/edit"} class="text-indigo-600 hover:underline">
            수정
          </.link>
        </:action>
      </.table>

      <.modal :if={@form} id="routing-modal" show on_cancel={JS.patch(~p"/admin/routings")}>
        <.header>{if @live_action == :new, do: "신규 라우팅", else: "라우팅 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:item_id]}
            type="select"
            label="품목"
            prompt="선택하세요"
            options={@item_options}
          />
          <.input
            field={@form[:process_id]}
            type="select"
            label="공정"
            prompt="선택하세요"
            options={@process_options}
          />
          <.input field={@form[:sequence]} type="number" label="순서" />
          <.input
            field={@form[:standard_cycle_time]}
            type="number"
            step="any"
            label="표준 사이클 타임 (초/개, 선택)"
          />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end

  defp item_label(map, id) do
    case Map.get(map, id) do
      nil -> "(삭제된 품목)"
      item -> "#{item.item_code} · #{item.name}"
    end
  end

  defp process_label(map, id) do
    case Map.get(map, id) do
      nil -> "(삭제된 공정)"
      process -> "#{process.process_code} · #{process.name}"
    end
  end
end
