defmodule OpenMesWeb.Admin.MasterData.WorkerLive do
  @moduledoc """
  기준정보 — 작업자(Worker) 관리 LiveView (목록/검색/필터 + 생성/수정 + 활성 토글).

  설계 §3.3(G1). 쓰기는 `OpenMes.MasterData` 컨텍스트 경유(AuditLog 내장). Repo 직접 호출 금지.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.MasterData.Worker

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "작업자 관리", query: "", active_filter: "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:form, nil) |> load_rows()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:form, to_form(MasterData.change_worker(%Worker{active: true})))
    |> assign(:editing_id, nil)
    |> load_rows()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case MasterData.get_worker(id) do
      nil ->
        socket |> put_flash(:error, "존재하지 않는 작업자입니다") |> push_patch(to: ~p"/admin/workers")

      worker ->
        socket
        |> assign(:form, to_form(MasterData.change_worker(worker)))
        |> assign(:editing_id, id)
        |> load_rows()
    end
  end

  @impl true
  def handle_event("search", %{"query" => query, "active" => active}, socket) do
    {:noreply, socket |> assign(query: query, active_filter: active) |> load_rows()}
  end

  def handle_event("validate", %{"worker" => params}, socket) do
    changeset = Worker.changeset(%Worker{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"worker" => params}, socket) do
    save_row(socket, socket.assigns.editing_id, params, socket.assigns.current_actor)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    actor = socket.assigns.current_actor

    case MasterData.get_worker(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "존재하지 않는 작업자입니다")}

      worker ->
        case MasterData.update_worker(id, %{"active" => !worker.active}, actor) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, if(worker.active, do: "비활성화했습니다", else: "활성화했습니다"))
             |> load_rows()}

          _ ->
            {:noreply, put_flash(socket, :error, "상태 변경에 실패했습니다")}
        end
    end
  end

  defp save_row(socket, nil, params, actor) do
    case MasterData.create_worker(params, actor) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "작업자를 생성했습니다") |> push_patch(to: ~p"/admin/workers")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_row(socket, id, params, actor) do
    case MasterData.update_worker(id, params, actor) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "작업자를 수정했습니다") |> push_patch(to: ~p"/admin/workers")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "존재하지 않는 작업자입니다")
         |> push_patch(to: ~p"/admin/workers")}
    end
  end

  defp load_rows(socket) do
    rows =
      MasterData.list_workers(filters(socket))
      |> filter_query(socket.assigns.query)

    assign(socket, :rows, rows)
  end

  defp filters(%{assigns: %{active_filter: "active"}}), do: %{"active" => "true"}
  defp filters(%{assigns: %{active_filter: "inactive"}}), do: %{"active" => "false"}
  defp filters(_socket), do: %{}

  defp filter_query(rows, ""), do: rows

  defp filter_query(rows, query) do
    q = String.downcase(query)

    Enum.filter(rows, fn r ->
      String.contains?(String.downcase(r.worker_code), q) or
        String.contains?(String.downcase(r.name), q)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="작업자 관리" subtitle="작업자 기준정보">
        <:actions>
          <.link patch={~p"/admin/workers/new"}>
            <.button>신규 작업자</.button>
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

      <.empty_state :if={@rows == []} message="등록된 작업자가 없습니다. '신규 작업자' 로 추가하세요." />

      <.table :if={@rows != []} id="workers" rows={@rows}>
        <:col :let={w} label="작업자코드">{w.worker_code}</:col>
        <:col :let={w} label="이름">{w.name}</:col>
        <:col :let={w} label="상태"><.active_badge active={w.active} /></:col>
        <:action :let={w}>
          <.link patch={~p"/admin/workers/#{w.id}/edit"} class="text-indigo-600 hover:underline">
            수정
          </.link>
        </:action>
        <:action :let={w}>
          <button
            type="button"
            phx-click="toggle_active"
            phx-value-id={w.id}
            data-confirm={if w.active, do: "비활성화하시겠습니까?", else: "활성화하시겠습니까?"}
            class="text-zinc-500 hover:underline"
          >
            {if w.active, do: "비활성", else: "활성"}
          </button>
        </:action>
      </.table>

      <.modal :if={@form} id="worker-modal" show on_cancel={JS.patch(~p"/admin/workers")}>
        <.header>{if @live_action == :new, do: "신규 작업자", else: "작업자 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:worker_code]} label="작업자코드" />
          <.input field={@form[:name]} label="이름" />
          <.input
            field={@form[:role]}
            type="select"
            label="역할"
            options={Enum.map(OpenMesWeb.Authorization.roles(), &{&1.label, &1.key})}
          />
          <.input field={@form[:active]} type="checkbox" label="활성" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end
end
