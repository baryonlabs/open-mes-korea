defmodule OpenMesWeb.Admin.Settings.ProductionLineLive do
  @moduledoc """
  설정 — 생산라인 구성 목록/생성/수정 LiveView(설계 22번 §3.2 A).

  라인 모니터가 읽는 라인 구성을 사람이 편집한다. 모든 쓰기는 `OpenMes.ProductionLine`
  컨텍스트 경유(AuditLog 내장). LiveView 는 Repo 를 직접 호출하지 않는다.

  live_action: :index(목록), :new(생성 폼), :edit(수정 폼).
  삭제 대신 active=false(비활성)로 이력을 보존한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.ProductionLine
  alias OpenMes.ProductionLine.Line

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "생산라인 구성")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:form, nil)
    |> load_lines()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:form, to_form(ProductionLine.change_line(%Line{active: true})))
    |> assign(:editing_id, nil)
    |> load_lines()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case ProductionLine.fetch_line(id) do
      {:ok, line} ->
        socket
        |> assign(:form, to_form(ProductionLine.change_line(line)))
        |> assign(:editing_id, id)
        |> load_lines()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 라인입니다")
        |> push_patch(to: ~p"/admin/settings/lines")
    end
  end

  @impl true
  def handle_event("validate", %{"line" => params}, socket) do
    changeset = Line.changeset(%Line{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"line" => params}, socket) do
    actor = socket.assigns.current_actor
    save_line(socket, socket.assigns.editing_id, params, actor)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    actor = socket.assigns.current_actor

    with {:ok, line} <- ProductionLine.fetch_line(id),
         {:ok, _} <- ProductionLine.update_line(id, %{"active" => !line.active}, actor) do
      {:noreply,
       socket
       |> put_flash(:info, if(line.active, do: "비활성화했습니다", else: "활성화했습니다"))
       |> load_lines()}
    else
      _ -> {:noreply, put_flash(socket, :error, "상태 변경에 실패했습니다")}
    end
  end

  defp save_line(socket, nil, params, actor) do
    case ProductionLine.create_line(params, actor) do
      {:ok, _line} ->
        {:noreply,
         socket
         |> put_flash(:info, "라인을 생성했습니다")
         |> push_patch(to: ~p"/admin/settings/lines")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_line(socket, id, params, actor) do
    case ProductionLine.update_line(id, params, actor) do
      {:ok, _line} ->
        {:noreply,
         socket
         |> put_flash(:info, "라인을 수정했습니다")
         |> push_patch(to: ~p"/admin/settings/lines")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "존재하지 않는 라인입니다")
         |> push_patch(to: ~p"/admin/settings/lines")}
    end
  end

  defp load_lines(socket) do
    lines = ProductionLine.list_lines()
    counts = ProductionLine.step_counts()
    assign(socket, lines: lines, step_counts: counts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header title="생산라인 구성" subtitle="라인 모니터가 표시할 라인·공정·설비 구성">
        <:actions>
          <.link patch={~p"/admin/settings/lines/new"}>
            <.button>신규 라인</.button>
          </.link>
        </:actions>
      </.page_header>

      <.empty_state
        :if={@lines == []}
        message="등록된 생산라인이 없습니다. '신규 라인' 으로 추가하세요."
      />

      <.table :if={@lines != []} id="lines" rows={@lines}>
        <:col :let={line} label="라인코드">{line.line_code}</:col>
        <:col :let={line} label="라인명">{line.name}</:col>
        <:col :let={line} label="단계 수">{Map.get(@step_counts, line.id, 0)}</:col>
        <:col :let={line} label="상태"><.active_badge active={line.active} /></:col>
        <:action :let={line}>
          <.link
            navigate={~p"/admin/settings/lines/#{line.id}/steps"}
            class="text-indigo-600 hover:underline"
          >
            구성 편집
          </.link>
        </:action>
        <:action :let={line}>
          <.link
            patch={~p"/admin/settings/lines/#{line.id}/edit"}
            class="text-indigo-600 hover:underline"
          >
            수정
          </.link>
        </:action>
        <:action :let={line}>
          <button
            type="button"
            phx-click="toggle_active"
            phx-value-id={line.id}
            data-confirm={if line.active, do: "비활성화하시겠습니까?", else: "활성화하시겠습니까?"}
            class="text-zinc-500 hover:underline"
          >
            {if line.active, do: "비활성", else: "활성"}
          </button>
        </:action>
      </.table>

      <.modal :if={@form} id="line-modal" show on_cancel={JS.patch(~p"/admin/settings/lines")}>
        <.header>{if @live_action == :new, do: "신규 라인", else: "라인 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:line_code]} label="라인코드 (예: LINE-INJ)" />
          <.input field={@form[:name]} label="라인명" />
          <.input field={@form[:description]} label="설명" />
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
