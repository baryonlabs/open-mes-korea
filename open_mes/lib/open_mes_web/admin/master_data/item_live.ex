defmodule OpenMesWeb.Admin.MasterData.ItemLive do
  @moduledoc """
  기준정보 — 품목(Item) 관리 LiveView (목록/검색/필터 + 생성/수정 + 활성 토글).

  설계 §3.3(G1 기준정보). 모든 쓰기는 `OpenMes.MasterData` 컨텍스트 경유(AuditLog 내장).
  LiveView 는 Repo 를 직접 호출하지 않는다.

  live_action: :index(목록), :new(생성 폼), :edit(수정 폼).
  삭제 대신 active=false(비활성)로 이력을 보존한다(설계 §0.6).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.MasterData.Item

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "품목 관리", query: "", active_filter: "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:form, nil)
    |> load_items()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:form, to_form(MasterData.change_item(%Item{active: true})))
    |> assign(:editing_id, nil)
    |> load_items()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case MasterData.fetch_item(id) do
      {:ok, item} ->
        socket
        |> assign(:form, to_form(MasterData.change_item(item)))
        |> assign(:editing_id, id)
        |> load_items()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 품목입니다")
        |> push_patch(to: ~p"/admin/items")
    end
  end

  @impl true
  def handle_event("search", %{"query" => query, "active" => active}, socket) do
    {:noreply, socket |> assign(query: query, active_filter: active) |> load_items()}
  end

  def handle_event("validate", %{"item" => params}, socket) do
    changeset = Item.changeset(%Item{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"item" => params}, socket) do
    actor = socket.assigns.current_actor
    save_item(socket, socket.assigns.editing_id, params, actor)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    actor = socket.assigns.current_actor

    with {:ok, item} <- MasterData.fetch_item(id),
         {:ok, _} <- MasterData.update_item(id, %{"active" => !item.active}, actor) do
      {:noreply,
       socket
       |> put_flash(:info, if(item.active, do: "비활성화했습니다", else: "활성화했습니다"))
       |> load_items()}
    else
      _ -> {:noreply, put_flash(socket, :error, "상태 변경에 실패했습니다")}
    end
  end

  defp save_item(socket, nil, params, actor) do
    case MasterData.create_item(params, actor) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "품목을 생성했습니다")
         |> push_patch(to: ~p"/admin/items")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_item(socket, id, params, actor) do
    case MasterData.update_item(id, params, actor) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "품목을 수정했습니다")
         |> push_patch(to: ~p"/admin/items")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:error, "존재하지 않는 품목입니다") |> push_patch(to: ~p"/admin/items")}
    end
  end

  defp load_items(socket) do
    items =
      MasterData.list_items(filters(socket))
      |> filter_query(socket.assigns.query)

    assign(socket, :items, items)
  end

  defp filters(%{assigns: %{active_filter: "active"}}), do: %{"active" => "true"}
  defp filters(%{assigns: %{active_filter: "inactive"}}), do: %{"active" => "false"}
  defp filters(_socket), do: %{}

  # 검색은 코드/이름 부분일치(서버 메모리 — pi, 목록 페이지 크기 내).
  defp filter_query(items, ""), do: items

  defp filter_query(items, query) do
    q = String.downcase(query)

    Enum.filter(items, fn item ->
      String.contains?(String.downcase(item.item_code), q) or
        String.contains?(String.downcase(item.name), q)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="품목 관리" subtitle="원자재/반제품/제품 기준정보">
        <:actions>
          <.link patch={~p"/admin/items/new"}>
            <.button>신규 품목</.button>
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="search" phx-submit="search" class="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-500">검색</label>
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="코드 / 이름"
            phx-debounce="300"
            class="mt-1 rounded-lg border-zinc-300 text-sm"
          />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">상태</label>
          <select name="active" class="mt-1 rounded-lg border-zinc-300 text-sm">
            <option value="all" selected={@active_filter == "all"}>전체</option>
            <option value="active" selected={@active_filter == "active"}>활성</option>
            <option value="inactive" selected={@active_filter == "inactive"}>비활성</option>
          </select>
        </div>
      </form>

      <.empty_state :if={@items == []} message="등록된 품목이 없습니다. '신규 품목' 으로 추가하세요." />

      <.table :if={@items != []} id="items" rows={@items}>
        <:col :let={item} label="품목코드">{item.item_code}</:col>
        <:col :let={item} label="이름">{item.name}</:col>
        <:col :let={item} label="유형">{item_type_label(item.item_type)}</:col>
        <:col :let={item} label="단위">{item.unit}</:col>
        <:col :let={item} label="상태"><.active_badge active={item.active} /></:col>
        <:action :let={item}>
          <.link patch={~p"/admin/items/#{item.id}/edit"} class="text-indigo-600 hover:underline">
            수정
          </.link>
        </:action>
        <:action :let={item}>
          <button
            type="button"
            phx-click="toggle_active"
            phx-value-id={item.id}
            data-confirm={if item.active, do: "비활성화하시겠습니까?", else: "활성화하시겠습니까?"}
            class="text-zinc-500 hover:underline"
          >
            {if item.active, do: "비활성", else: "활성"}
          </button>
        </:action>
      </.table>

      <.modal
        :if={@form}
        id="item-modal"
        show
        on_cancel={JS.patch(~p"/admin/items")}
      >
        <.header>{if @live_action == :new, do: "신규 품목", else: "품목 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:item_code]} label="품목코드" />
          <.input field={@form[:name]} label="이름" />
          <.input
            field={@form[:item_type]}
            type="select"
            label="유형"
            options={item_type_options()}
          />
          <.input field={@form[:unit]} label="단위 (예: EA, kg)" />
          <.input field={@form[:active]} type="checkbox" label="활성" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end

  defp item_type_options do
    [{"원자재", "raw"}, {"반제품", "semi"}, {"제품", "product"}]
  end

  defp item_type_label("raw"), do: "원자재"
  defp item_type_label("semi"), do: "반제품"
  defp item_type_label("product"), do: "제품"
  defp item_type_label(other), do: other
end
